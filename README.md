# azure-vm-vmstartstop

## Overview
This script is an adaptation of the one found at: https://github.com/dnewsholme/Invoke-Autoshutdown.

This PowerShell script is intended to run as an Azure Automation runbook to automatically start and stop VMs based on specific values in their tags.

Key details of this script:
- Intended to run every hour, but that can be changed by setting the `$TimeResolution` parameter/variable. NOTE that Azure Automation only allows recurring schedules at a minimum of 1 hour, but you could theoretically create multiple schedules that run once an hour and "stagger" them by 10/15/30 etc. minutes.
  - Does not currently support running *less* often than one hour. This will be addressed in a future release.
- For simplicity, this script only supports ARM VMs and Resource Groups. Tags applied to Resource Groups will apply to all VMs in the group. An exception system may be added in a future release.
- The script can only run against one Azure subscription at a time. This may change in a future release.
- The script will only perform an action once, during the run window in which it is scheduled. The "adapted" script listed above would power on/off a machine each time the script ran (if the machine had been manually powered on or off after the script ran).
- This script only supports weekly schedules. You can specify "M.W.F", "F-Su", "M.Tu-Th.Sa", or "all" for the date section of a tag. Support for specific calendar dates probably won't be added, so feel free to fork and go nuts!
- The script supports start-only or stop-only schedules. For example, if you want to make sure that certain VMs stop at 6PM but don't want them to auto-start, you'd set the VMs' tag to "none,6PM,all"
- If the stop time is "earlier" than the start time, the script assumes it is for the following day. So if a VM has a schedule of "8AM, 2AM, M", the script would start the VM at 8AM Monday and stop it at 2AM Tuesday.
  - If the auto-start is disabled ("None"), the stop time is assumed for the same day. So if a VM has a schedule of "None, 2AM, M", the script would stop the VM at 2AM Monday.
- All times/schedules are in UTC
- 12-hour and 24-hour time formats are supported

## Usage
1. Create an Automation PowerShell runbook (not a PowerShell Workflow because that was troublesome so I abandoned it).
2. Paste in the code from "runbook.ps1".
3. Set a tag on the VMs you want to auto-start/stop.
  - Tag name: "VMAutoStartStop" (can be changed using a parameter or updating the default value in the script)
  - Tag value: `<start time>,<stop time>,<weekly schedule>` where:
    - *start time* is a valid time format (7AM, 7:05 AM, 13:30). Can also be set to "None" to disable auto-start
    - *stop time* is a valid time format (8PM, 8:05 AM, 1:30). Can also be set to "None" to disable auto-stop.
    - *weekly schedule* is a string of abbreviated days ("Su","M","Tu","W","Th","F","Sa") or day ranges (M-F, Tu-Th) separated by periods. You can mix days and date ranges: M.T.Th-Sa    

## Parameters
When executing the runbook, there are several parameters available. You can modify their default values in the script, or set the parameters in your execution/schedule.
- AzureSubscriptionName: *string*. If set to "Default", the script will look for a variable in your Azure Automation account named "Default Azure Subscription". If you don't want to set an Automation Variable, provide your subscription name
- TagName: *string*. The name of the Resource Manager tag to look for on VMs. the default value is "VMAutoStartStop". If you wanted to have different schedules, you could set multiple tags on your VMs and run the script with a different -TagName parameter for each one. I dunno, just a thought. I won't tell you how to live your life.
- Simulate: *boolean*. Defaults to "True". In simulate mode, the script **will not** start/stop VMs, it will simply log things to the output. This is a failsafe from the original script. You must set `-Simulate:$False` (or change the default value in the script) for the script to actually do things
- TimeResolution: *integer*. Default is '60'. The number of minutes to use as a "run window". Basically, when the script runs, it will take the current "hour" (*e.g.*, 7AM) and divide by this number. Then it will find which "chunk" of time it is currently running in, and will only process schedules that are included in that chunk. Some examples for clarity:
  - TimeResolution = 60. The script should be scheduled every hour. The script starts at 7:01AM. The time chunk will be 7AM-7:59:59AM. The script will run start/stop commands for any scheduled time between that chunk. A VM with a start value of 7:15AM would be processed at this time.
  - TimeResolution = 15. The script shoudl be scheduled every 15 minutes. The script starts at 7:01AM. The time chunk will be 7AM-7:14:59AM. The script will run start/stop commands for any scheduled time between that chunk. A VM with a start value of 7:15AM would not be processed. The script runs again at 7:16AM. The time chunk will be 7:15AM-7:29:59AM. A VM with a start value of 7:15AM would be processed at this time.
