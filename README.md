<!---
Test changes using: http://daringfireball.net/projects/markdown/dingus
-->

# xs-backup

Backup script for Citrix XenServer, based on the original script by Mark
Round <github@markround.com>:

[http://www.markround.com/snapback](http://www.markround.com/snapback)

[https://github.com/markround/XenServer-snapshot-backup](https://github.com/markround/XenServer-snapshot-backup)

**WARNING: THIS SCRIPT DOES NOT CURRENTLY WORK WITH XENSERVER 6.2**

## Overview

The script creates a snapshot of a running VM on a configurable schedule, and
then creates a template from this snapshot. It will copy all these backup
templates over to a configurable storage repository, and then clean up any old
backups according to a specified retention policy. These backups are full
backups, so if you have a 10GB VM and keep 7 previous copies you will need a
total of 80GB disk space on your backup VM. Non-running VMs, and those not
configured (as detailed below) will be skipped.

*Important*: See [KB CTX123400](http://support.citrix.com/article/CTX123400).
After backing up each VM, you will end up with a new VDI, so you may need to
manually coalesce your VDIs again to reclaim disk space. This appears to have
been fixed in 5.6FP1, however.

## Installation and Usage

First, copy the script to your Xenserver pool master, and make it executable. A
good location for this is

    /usr/local/bin/xs-snapback

**THIS SECTION IS CURRENTLY OUT OF DATE**

Next, create a cron entry for the script - to make it run daily just after 1AM,
you'd create /etc/cron.d/xs-backup with the following contents:

    2 1 * * * root /usr/local/bin/xs-snapback.sh > /var/log/xs-snapback.log 2>&1

TODO: explain SR as cmd line opt

### XenCenter Configuration

Lastly, you need to configure your backup and retention policy for your VMs. In
Xencenter, right click your VM, and select "Properties". Click on "Custom
Fields", and then "Edit Custom Fields". You should add two text fields :

* `backup`

   Can be one of `daily`, `weekly`, or `monthly`. If it is set to
weekly, it will by default run on a Sunday, and if it set to monthly, it
will run on the first Sunday of the month.

* `retain`

   How many previous backups (in addition to the currently running
backup) to keep. So, setting this to a value of "2" would mean that after
a backup has run, you would end up with 3 backups in total.

The script will look for these fields when it is run, and will skip any VM
that doesn't have them set. You can also see them in the XenCenter summary
and properties for the VM.

You can now either run the script manually, or wait until the cron job
kicks off. It will produce a detailed log to the console (or log file if
run through cron), and when it's finished, you'll see your template backup
VMs listed in Xencenter.

If you find that this clutters up the Xencenter view a little, you can always
hide them (View->Server View->Custom Templates).

To restore a VM from a backup, just right click, and choose "New template
from backup".
