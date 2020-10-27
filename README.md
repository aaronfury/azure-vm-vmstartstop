# azure-vm-vmstartstop

## Overview
This script is an adaptation of the one found at: https://github.com/dnewsholme/Invoke-Autoshutdown.

This PowerShell script is intended to run as an Azure Automation runbook to automatically start and stop VMs based on specific values in their tags.

Key details of this script:
- Intended to run every hour, but that can be changed by setting the `$TimeResolution` parameter/variable. NOTE that Azure Automation only allows recurring schedules at a minimum of 1 hour, but you could theoretically create multiple schedules that run once an hour and "stagger" them by 10/15/30 etc. minutes.
- The script will only perform an action once, during the run window in which it is scheduled. The "adapted" script listed above would power on/off a machine each time the script ran (if the machine had been manually powered on or off after the script ran).
- This script only supports weekly schedules. You can specify "M.W.F", "F-Su", "M.Tu-Th.Sa", or "all" for the date section of a tag. Support for specific calendar dates probably won't be added, so feel free to fork and go nuts!
- The script supports start-only or stop-only schedules. For example, if you want to make sure that certain VMs stop at 6PM but don't want them to auto-start, you'd set the VMs' tag to "none,6PM,all"
- All times/schedules are in UTC
- 12-hour and 24-hour time formats are supported
