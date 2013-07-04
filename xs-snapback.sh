#!/bin/bash
# xs-snapback; XenServer backup script.
# Based on snapback.sh 1.4 by Mark Round, http://www.markround.com/snapback

set -u  # fail on unbound vars
set -e  # die on any error

# Confguration Variables
SNAPSHOT_SUFFIX='snapback'  # Temp snapshots will be use this as a suffix
TEMP_SUFFIX='newbackup'     # Temp backup templates will use this as a suffix
BACKUP_SUFFIX='backup'      # Backup templates will use this + date as a suffix
WEEKLY_ON='Sun'             # What day to run weekly backups on
MONTHLY_ON='Sun'            # What day to run monthly backups on. These will run
                            # on the first day specified below of the month.
LOCKFILE=/var/run/snapback.pid

#
# Don't modify below this line
#

SECTION_BREAK='
==============================================================================='

# user supplied info
# note we have to temporarily disable the unbound
# variable check in case the user did not supply
set +u
TEMPLATE_SR="$1"  # UUID of the destination SR for backups
XVA_SR="$2"       # UUID of the destination SR for XVA files it must be an NFS SR
set -u

# check the XVA SR is a valid mount point
if [ -z "$XVA_SR" ]  ; then
  echo "Usage: XVA SR does not appear to be a valid NFS or CIFS SR"
  exit 1
fi
if ! mountpoint -q /var/run/sr-mount/"$XVA_SR/" ; then
  echo "Error: XVA SR does not appear to be a valid NFS or CIFS SR"
  exit 1
fi

# enable noclobber bash option then attempt to create our lock file.
# this is much more atomic than checking for the log file first before
# creating it.
set -C
echo $$ > $LOCKFILE || { "Lockfile $LOCKFILE exists, exiting!"; exit 1; }
set +C
# cleanup our lockfile any time we exit
trap "rm -f $LOCKFILE; exit" INT TERM EXIT

# Date format must be %Y%m%d so we can sort them
ymd_date=$(date +"%Y%m%d")


function logmsg {
  local _msg=${1-}
  logger -t xs-snapback "$_msg"
  return 0
}

# Quick hack to grab the required paramater from the output of the xe command
function xe_param() {
  _param="$1"
  # TODO: this can be done using bash string manipulation to save
  #       creating extra processes.
  while read _data ; do
    _line=$(echo $_data | egrep "$_param")
    if [ $? -eq 0 ]; then
      echo "$_line" | awk 'BEGIN{FS=": "}{print $2}'
    fi
  done
}

# Deletes a snapshot's VDIs before uninstalling it. This is needed as
# snapshot-uninstall seems to sometimes leave "stray" VDIs in SRs
function delete_snapshot() {
  local _delete_uuid="$1"

  # delete the associated vdi's first
  for _vdi_uuid in $(xe vbd-list vm-uuid=$_delete_uuid empty=false | xe_param "vdi-uuid"); do
    #echo "Deleting snapshot VDI : $_vdi_uuid"
    xe vdi-destroy uuid=$_vdi_uuid
  done

  # Now we can remove the snapshot itself
  xe snapshot-uninstall uuid="$_delete_uuid" force=true
}

# See above - templates also seem to leave stray VDIs around...
function delete_template() {
  local _delete_uuid="$1"

  # delete the associated vdi's first
  for _vdi_uuid in $(xe vbd-list vm-uuid=$_delete_uuid empty=false | xe_param "vdi-uuid"); do
    xe vdi-destroy uuid=$_vdi_uuid
  done

  # Now we can remove the template itself
  xe template-uninstall template-uuid=$_delete_uuid force=true
}

function check_schedule() {
  local _schedule="$1"
  local _retain_num="$2"

  # we can't compare anything if we have nothing to compare
  if [ -z "$_schedule" ] || [ -z "$_retain_num" ] ; then
    logmsg "No schedule or retention set for backup; SKIPPING BACKUP"
    return 1
  fi

  case "$_schedule" in
    'daily')
      logmsg "Going to do a daily backup for this VM"
      return 0
      ;;
    'weekly')
      # If weekly, see if this is the correct day
      if [ "$(date +'%a')" == "$WEEKLY_ON" ]; then
        logmsg "Going to do a weekly backup today"
        return 0
      else
        logmsg "Weekly backup scheduled for $WEEKLY_ON which isn't today; SKIPPING"
        return 1
      fi
      ;;
    'monthly')
      # If monthly, see if this is the correct day
      if [ "$(date +'%a')" == "$MONTHLY_ON" ] && [ $(date '+%e') -le 7 ]; then
        logmsg "Going to do a monthly backup today"
        return 0
      else
        logmsg "Monthly backup scheduled for 1st $MONTHLY_ON which isn't today; SKIPPING"
        return 1
      fi
      ;;
  esac

  logmsg "Invalid backup schedule; SKIPPING TEMPLATE BACKUP"
  return 1
}


function snapshot_name() {
  local _vm_name="$1"
  echo "$_vm_name-${SNAPSHOT_SUFFIX}"
}

function prepare_vm_for_backup() {
  ### Take a snapshot of the running VM #####################################
  # This is what we take our actual backups from. First we need to check
  # for a previous snapshot that matches our snapshot name pattern and
  # delete it (this could happen if a previous backup fails early)
  local _vm_name="$1"
  local _snapshot_name=$(snapshot_name ${_vm_name})

  # check for existing backup snapshot and delete if found
  local _previous_snapshots=$(xe snapshot-list name-label="$_snapshot_name" | xe_param uuid)
  if [ -n "$_previous_snapshots" ] ; then
    # _previous_snapshots will be new-line delimited list if there are multiple
    # old snapshots, so we need to loop over them
    for X in "$_previous_snapshots" ; do
      logmsg "Deleting expired snapshot $X"
      delete_snapshot $X > /dev/null
    done
  fi

  logmsg "Creating new snapshot '$_snapshot_name'"
  local _snapshot_uuid=$(xe vm-snapshot vm="$_vm_name" new-name-label="$_snapshot_name")

  echo $_snapshot_uuid
}

function do_template_backup() {
  local _vm_name="$1"
  local _working_snapshot="$2"
  local _snapshot_name=$(snapshot_name ${_vm_name})
  local _template_name_label="${_vm_name}-${BACKUP_SUFFIX}-${ymd_date}"

  # Check there isn't a stale template with TEMP_SUFFIX name hanging around from a failed job
  TEMPLATE_TEMP="$(xe template-list name-label="${_vm_name}-${TEMP_SUFFIX}" | xe_param uuid)"
  if [ -n "$TEMPLATE_TEMP" ] ; then
    logmsg "Found a stale temporary template, removing UUID $TEMPLATE_TEMP"
    echo "     Found a stale temporary template, removing"
    delete_template $TEMPLATE_TEMP
  fi

  logmsg "Copying working snapshot '$_snapshot_name' to SR '$TEMPLATE_SR'"
  echo "     Copying working snapshot to template SR..."
  TEMPLATE_UUID=$(xe snapshot-copy uuid=$_working_snapshot sr-uuid=$TEMPLATE_SR new-name-description="Snapshot created on $(date)" new-name-label="$_vm_name-$TEMP_SUFFIX")

  # Also check there is no template with the current timestamp.
  # Otherwise, you would not be able to backup more than once a day if you needed...
  local _old_backup_uuid="$(xe template-list name-label="$_template_name_label" | xe_param uuid)"
  if [ -n "$_old_backup_uuid" ] ; then
    logmsg "Found a template already for today, removing UUID $_old_backup_uuid"
    echo "     Found a template already for today, removing UUID $_old_backup_uuid"
    delete_template $_old_backup_uuid
  fi

  logmsg "Moving new backup into place as $_template_name_label"
  echo "     Moving new backup into place as $_template_name_label"
  xe template-param-set name-label="$_template_name_label" uuid=$TEMPLATE_UUID
}

function cleanup_template_backups() {
  local _vm_name="$1"
  local _retain_num="$2"

  # List templates for all VMs, grep for $_vm_name-$BACKUP_SUFFIX
  # Sort -n, head -n -$RETAIN
  # Loop through and remove each one
  logmsg "Removing expired template backups outside retention period"
  echo " "
  echo "   Removing expired template backups outside retention period"
  xe template-list | \
    grep "$_vm_name-$BACKUP_SUFFIX" | \
    xe_param name-label | \
    sort -n | \
    head -n-$_retain_num | \
    while read _expired_backup ; do
      _expired_backup_uuid=$(xe template-list name-label="$_expired_backup" | xe_param uuid)
      delete_template $_expired_backup_uuid
  done
}

function do_xva_backup() {
  local _vm_name="$1"
  local _working_snapshot="$2"
  local _xva_sr="$3"
  local _snapshot_name=$(snapshot_name ${_vm_name})
  local _xva_file="/var/run/sr-mount/${_xva_sr}/${_vm_name}-${BACKUP_SUFFIX}-${ymd_date}.xva"

  logmsg "Export target is: $_xva_file"
  echo " "
  echo "   Export target is: $(basename $_xva_file)"

  # Check there is not already a backup made with todays date, otherwise, we
  # can't do this backup because `xe vm-export` will barf.
  local _rolled_backup_fname="${XVA_FILEi}.1"
  if [ -e "$_xva_file" ] ; then
    logmsg "Found a previous backup for today; rolling to $(basename $_rolled_backup_fname)"
    echo "     Found a previous backup for today; rolling to $(basename $_rolled_backup_fname)"
    mv -f "${_xva_file}" "${_rolled_backup_fname}"
  fi

  # Creates a XVA file from the snapshot
  echo -n "     Starting export... "
  xe vm-export vm=$_working_snapshot filename="$_xva_file" \
    && echo "OK" \
    || echo "FAIL"

  # remove previous rolled backup (from earlier today)
  if [ -e "$_rolled_backup_fname" ] ; then
    logmsg "Removing previous backup from earlier today"
    echo "     Removing previous backup from earlier today"
    rm -f "$_rolled_backup_fname"
  fi
}

function cleanup_xva_backups() {
  local _vm_name="$1"
  local _retain_num="$2"
  local _xva_sr="$3"

  # List XVA files for all VMs, grep for $_vm_name-$BACKUP_SUFFIX
  # Sort -n, head -n -$RETAIN
  # Loop through and remove each one
  echo "    Removing expired XVA backups outside retention period"
  logmsg "Removing expired XVA backups outside retention period"
  ls -1 /var/run/sr-mount/$_xva_sr/*.xva | \
    grep "$_vm_name-$BACKUP_SUFFIX" | \
    sort -n | \
    head -n-$_retain_num | \
    while read OLD_TEMPLATE; do
      echo "   Removing : $(basename $OLD_TEMPLATE)"
      rm -f $OLD_TEMPLATE \
        && echo "    Done" \
        || echo "    ERROR"
  done
}



logmsg "Started"
echo ""
echo "Snapshot backup started at $(date)"
echo ""

# Get all running VMs
# note: this does list all running VM's in the pool, regardless of the host.
# tested on 6.0.2 pool with 2 hosts by fukawi2 20120921
RUNNING_VMS=$(xe vm-list power-state=running is-control-domain=false | xe_param uuid)

for vm_uuid in $RUNNING_VMS; do
  vm_name="$(xe vm-list uuid=$vm_uuid | xe_param name-label)"
  logmsg "Processing $vm_name"
  echo $SECTION_BREAK
  echo "=> Backup for $vm_name started at $(date)"

  # Useful for testing, if we only want to process one VM
#  if [ "$vm_name" != "testvm" ]; then
#      continue
#  fi

  # we assume we want to backup this vm unless the schedule
  # tells us otherwise. these vars should get explicitly set
  # in the schedule check, but this is a safe default here.
  SKIP_TEMPLATE=0
  SKIP_XVA=0

  logmsg "Retrieving backup paramaters"
  echo "   Retrieving backup paramaters"
  # Template backups
  SCHEDULE=$(xe vm-param-get uuid=$vm_uuid param-name=other-config param-key=XenCenter.CustomFields.backup 2>/dev/null || true)
  RETAIN=$(xe vm-param-get uuid=$vm_uuid param-name=other-config param-key=XenCenter.CustomFields.retain 2>/dev/null || true)
  # XVA Backups
  XVA_SCHEDULE=$(xe vm-param-get uuid=$vm_uuid param-name=other-config param-key=XenCenter.CustomFields.xva_backup 2>/dev/null || true)
  XVA_RETAIN=$(xe vm-param-get uuid=$vm_uuid param-name=other-config param-key=XenCenter.CustomFields.xva_retain 2>/dev/null || true)

  logmsg "Template schedule is '$SCHEDULE'"
  logmsg "Template retention is $RETAIN"
  logmsg "XVA schedule is '$XVA_SCHEDULE'"
  logmsg "XVA retention is $XVA_RETAIN"
  echo "     Template schedule is:  $SCHEDULE"
  echo "     Template retention is: $RETAIN"
  echo "     XVA schedule is:       $XVA_SCHEDULE"
  echo "     XVA retention is:      $XVA_RETAIN"

  # Not using this yet, as there are some bugs to be worked out...
  # QUIESCE=$(xe vm-param-get uuid=$vm_uuid param-name=other-config param-key=XenCenter.CustomFields.quiesce)

  ### Check Template Schedule ###############################################
  logmsg "Comparing template backup schedule..."
  echo "   Comparing template backup schedule..."
  check_schedule "$SCHEDULE" "$RETAIN" || SKIP_TEMPLATE=1

  ### Check XVA Schedule ####################################################
  logmsg "Comparing XVA backup schedule..."
  echo "   Comparing XVA backup schedule..."
  check_schedule "$XVA_SCHEDULE" "$XVA_RETAIN" || SKIP_XVA=1

  ### Is this VM scheduled to be backed up? #################################
  if [ "$SKIP_TEMPLATE" == "1" ] && [ "$SKIP_XVA" == "1" ]; then
    logmsg "No backup scheduled for this VM today; Moving on."
    echo "   No backup scheduled for this VM today; Moving on."
    continue
  fi

  ### THIS IS WHERE WE START DOING BACKUPS ####################################
  echo " "
  echo "   Preparing working snapshot for VM $vm_name"
  echo -n "      Please wait... "
  snapshot_uuid=$(prepare_vm_for_backup "$vm_name" )
  echo "Done!"
  echo "      UUID is $snapshot_uuid"
  
  ### Backup the working snapshot to a template ###############################
  if [ -n "$TEMPLATE_SR" ] && [ "$SKIP_TEMPLATE" == "0" ]; then
    logmsg "Starting template backup"
    echo " "
    echo "   Starting template backup"
    do_template_backup "$vm_name" "$snapshot_uuid"
    cleanup_template_backups "$vm_name" "$RETAIN"
  fi

  ### Backup the working snapshot to a XVA file ###############################
  if [ -n "$XVA_SR" ] && [ "$SKIP_XVA" == "0" ]; then
    logmsg "Starting XVA backup"
    echo " "
    echo "   Starting XVA backup"
    do_xva_backup "$vm_name" "$snapshot_uuid" "$XVA_SR"
    cleanup_xva_backups "$vm_name" "$XVA_RETAIN" "$XVA_SR"
  fi

  ### Cleanup
  logmsg "Removing working snapshot"
  echo " "
  echo "   Removing working snapshot"
  delete_snapshot $snapshot_uuid

  logmsg "Backup for $vm_name completed"
  echo " "
  echo "====> Backup for $vm_name completed at $(date) =="
  echo " "
done

###############################################################################
# dump some metadata to disk with the backups
if [ -n "$TEMPLATE_SR" ] ; then
  logmsg "Backing up meta-data and mappings"
  echo $SECTION_BREAK
  echo "====> Backing up meta-data and mappings =="
  logmsg "Dumping VDI list to mapping.txt"
  xe vdi-list sr-uuid=$TEMPLATE_SR > /var/run/sr-mount/$TEMPLATE_SR/mapping.txt
  logmsg "Dumping VDB list to vdb-mapping.txt"
  xe vbd-list > /var/run/sr-mount/$TEMPLATE_SR/vbd-mapping.txt
  logmsg "Dumping pool meta-data"
  xe-backup-metadata -c -k 10 -u $TEMPLATE_SR
fi

echo $SECTION_BREAK
echo "=== Snapshot backup finished at $(date) ==="
logmsg "Completed; Exiting"

exit 0
