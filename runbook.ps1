Param (
    [string]$AzureSubscriptionName ="Default",
    [string]$TagName ="VMAutoStartStop",
    [bool]$Simulate = $true,
    [int]$TimeResolution = 60 # The resolution is how often, in minutes, the script will run. This will be used to "chunk" timestamps.
)

# Function which parses the tag value and determines whether an action should be taken
Function Get-ScheduledAction {
    Param(
        [string]$TagValue
    )
    $tagStart,$tagStop,$tagDays = $TagValue -split ","
    $tagStart,$tagStop,$tagDays | ForEach { If ( $_ -eq $null ) { Return "Invalid Tag"}}

    $tagStart = [DateTime]::Parse($tagStart)
    $tagStop = [DateTime]::Parse($tagStop)
    # If the stop time is earlier than the start time, assume the stop time is for the following day
    If ( $tagStop -le $tagStart ) {
        $stopTomorrow = $true
    }

    If ( $tagDays -eq "all" ) {
        $ActiveStartDays = $DayAbbrs
    } Else {
        $ActiveStartDays = @()
        $Days = $tagDays -split "\." # Split uses regex by default, need to escape the dot character
        ForEach ( $day in $Days ) {
            If ( $day -like "*-*" ) {
                $rangeStart, $rangeEnd = $day -split "-"
                $rangeStartIndex = $DayAbbrs.IndexOf($rangeStart)
                $rangeEndIndex = $DayAbbrs.IndexOf($rangeEnd)
                If ( $rangeStartIndex -le $rangeEndIndex ) {
                    $ActiveStartDays += $DayAbbrs[$rangeStartIndex..$rangeEndIndex]
                } Else {
                    $ActiveStartDays += $DayAbbrs[$rangeStartIndex..($DayAbbrs.Count-1)]
                    $ActiveStartDays += $DayAbbrs[0..$rangeEndIndex]
                }
            } Else {
                $ActiveStartDays += $day
            }
        }
    }

    # If the stop time IS for the following day, shift the stop days ahead by one from the start days
    If ( $stopTomorrow ) {
        $ActiveStopDays = $(
            $ActiveStartDays | ForEach {
                If ( $DayAbbrs[$DayAbbrs.IndexOf($_) + 1] ) {
                    $DayAbbrs[$DayAbbrs.IndexOf($_) + 1]
                } Else {
                    $DayAbbrs[0]
                }
            }
        )
    # If it's for the same day, copy the start days to the stop days
    } Else {
        $ActiveStopDays = $ActiveStartDays
    }

    # If today is in the start days...
    If ( $CurrentDayAbbr -in $ActiveStartDays ) {
        # And the start time is in the current time chunk
        If ( $tagStart -ge $ChunkStart -and $tagStart -le $ChunkEnd ) {
            # Set the action to start
            Return "Start"
        }
    }
    # If today is in the stop days...
    If ( $CurrentDayAbbr -in $ActiveStopDays ) {
        # And the stop time is in the current time chunk
        If ( $tagStop -ge $ChunkStart -and $tagStop -le $ChunkEnd ) {
            # Set the action to stop
            Return "Stop"
        }
    }

    # If no rules are matched, set the action to none
    Return "None"
}

# Calculate time chunk
$CurrentTime = (Get-Date).ToUniversalTime()
$DayAbbrs = @("Su","M","Tu","W","Th","F","Sa")
$CurrentDayAbbr = $DayAbbrs[$CurrentTime.DayOfWeek]
# This roundabout way of doing it (convert to DateTime, then parse, then reset to hour) gets rid of extra ticks that would affect the timestamp comparison
$CurrentHour = ([DateTime]::Parse($CurrentTime.DateTime)).AddMinutes(-$CurrentTime.Minute).AddSeconds(-$CurrentTime.Second)
$PrevTime = $CurrentHour
$PossibleChunks = @($CurrentHour)
Do {
    $NewTime = $PrevTime.AddMinutes($TimeResolution)
    If ( $CurrentHour.Hour -eq $NewTime.Hour ) {
        $PossibleChunks += $NewTime
    }
    $PrevTime = $NewTime
} While ( $CurrentHour.Hour -eq $NewTime.Hour )

$PossibleChunks += $CurrentHour.AddMinutes(59)

For ( $i = 1; $i -lt $PossibleChunks.Count; $i++ ) {
    If ( $CurrentTime -ge $PossibleChunks[$i-1] -and $CurrentTime -le $PossibleChunks[$i] ) {
        $ChunkStart = $PossibleChunks[$i-1]
        $ChunkEnd = $PossibleChunks[$i]
    }
}

Write-Output "All times UTC"
Write-Output "[$($CurrentTime.ToString("dddd, MM/dd/yyyy HH:mm:ss tt"))] Starting VMAutoStartStop Script"
Write-Output "This run will perform VM start/stop actions tagged between $($ChunkStart.ToShortTimeString()) and $($ChunkEnd.ToShortTimeString())"

If ( $Simulate -eq $true ) {
    Write-Output "Running in simulate mode... no power actions will actually be performed."
}

# Get Azure runbook automation variables.
If ( $AzureSubscriptionName -eq "Default" ) {
    $AzureSubscriptionName = Get-AutomationVariable -Name "Default Azure Subscription"
}
If ( $AzureSubscriptionName.Length -gt 1 ) {
    Write-Output "Using Subscription $AzureSubscriptionName"
} Else {
    Throw "No Subscription Specified."
}

# Begin Azure Login

# Get the connection "AzureRunAsConnection"
$servicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection"

Write-Output "Signing in to Azure..."
$attempts = 0
While ( -not $connection -and $attempts -le 5 ) {
    $attempts++
    $connection = Add-AzureRmAccount -ServicePrincipal -Tenant $servicePrincipalConnection.TenantId -ApplicationId $servicePrincipalConnection.ApplicationId -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint
    Start-Sleep -Seconds 5
}
If ( -not $connection ) {
    Throw "Failed to authenticate against Azure AD. No additional details are available."
} Else {
    Write-Output "Connected to Azure using the Automation RunAs account"
}

Write-Output "Setting context to $AzureSubscriptionName"
$context = Set-AzureRmContext -SubscriptionName $AzureSubscriptionName

# Get all resource manager VMs that have the tag
$taggedVMs = Get-AzureRmVM | Where-Object { $_.Tags.Keys -eq $TagName | Sort-Object Name }

# Get resource groups that have the tag
$taggedResourceGroups = @(Get-AzureRmResourceGroup | Where-Object {$_.Tags.Keys -eq $TagName | Sort-Object Name })

# Initialize Variables for VMs to be started and stopped
$VMsToStart = @()
$VMsToStop = @()

# Enumerate VMs in tagged Resource Groups first (so that individual VM tags will override these)
ForEach ( $rg in $taggedResourceGroups ) {
    Write-Output "Checking Resource Group $($rg.Name) with tag value '$($rg.Tags[$TagName])'"
    # Check if the RG tag should be processed during the current chunk
    $action = Get-ScheduledAction -TagValue $rg.Tags[$TagName]
    If ( $action -eq "Invalid tag" ) {
        Write-Error "Could not parse tag on $($rg.Name). Skipping..."
    } ElseIf ( $action -eq "None" ) {
        Write-Output "Resource Group '$($rg.Name)' isn't scheduled for action right now. Continuing."
    } Else {
        # Some action is to be taken, so get the VMs in the resource group
        $rgVMs = Get-AzureRMVm -ResourceGroupName $rg.Name
        If ( $action -eq "Start" ) {
            Write-Output "Setting $($rgVMs.Count) VMs from resource group to be started"
            $VMsToStart += $rgVMs
        } ElseIf ( $action -eq "Stop" ) {
            Write-Output "Setting $($rgVMs.Count) VMs from resource group to be stopped"
            $VMsToStop += $rgVMs
        }
    }
}

# Perform same enumeration on VMs with direct tags
Foreach ( $vm in $taggedVMs ) {
    Write-Output "Checking VM $($vm.Name) with tag value '$($vm.Tags[$TagName])'"
    # Check if the RG tag should be processed during the current chunk
    $action = Get-ScheduledAction -TagValue $vm.Tags[$TagName]
    If ( $action -eq "Invalid tag" ) {
        Write-Error "Could not parse tag on $($vm.Name). Skipping..."
    } ElseIf ( $action -eq "None" ) {
        Write-Output "Resource Group '$($vm.Name)' isn't scheduled for action right now. Continuing."
    } Else {
        # Some action is to be taken, so get the VMs in the resource group
        If ( $action -eq "Start" ) {
            Write-Output "Setting $($vm.Name) to be started"
            $VMsToStart += $vm
        } ElseIf ( $action -eq "Stop" ) {
            Write-Output "Setting $($vm.Name) to be stopped"
            $VMsToStop += $vm
        }
    }
}

# Loop through the array in parallel and stop VMs
If ( $VMsToStop ) {
    Write-Output "Stopping $($VMsToStop.Count) VMs"
}
Foreach ($vm in $VMsToStop){
    If ( $Simulate -eq $true ) {
        Write-Output "$($vm.Name) - Simulated Stop"
    } Else {
        # Obtain Current Powerstate.
        $powerstate = (((Get-AzureRmVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status -WarningAction SilentlyContinue).Statuses.Code) | Select-String -Pattern "(?<=PowerState\/)[A-z]+").Matches.Value
        # If currently running send a shutdown command
        If ( $powerstate -eq "running" ) {
            Write-Output "$($vm.Name) - Stopping"
            $vm | Stop-AzureRmVM -Force
        } Else {
            Write-Output "$($VM.Name) - Already Stopped"
        }
    }
}

# Loop through the array in parallel and start VMs
If ( $VMsToStart ) {
    Write-Output "Starting $($VMsToStart.Count) VMs"
}
Foreach ($vm in $VMStoStart){
    If ( $Simulate -eq $true ) {
        Write-Output "$($vm.Name) - Simulated Start"
    } Else {
        # Obtain Current Powerstate.
        $powerstate = (((Get-AzureRmVM -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status -WarningAction SilentlyContinue).Statuses.Code) | Select-String -Pattern "(?<=PowerState\/)[A-z]+").Matches.Value
        # If currently shutdown send a start command
        If ( $powerstate -ne "running" ) {
            Write-Output "$($VM.Name) - Starting"
            $vm | Start-AzureRmVM
        } Else {
            Write-Output "$($VM.Name) - Already started"
        }
    }
}

Write-Output "VMs shutdown: $($VMstoStop.count)"
Write-Output "VMs started: $($VMstoStart.count)"
Write-Output "Runbook finished [Duration: $(("{0:hh\:mm\:ss}" -f ((Get-Date).ToUniversalTime() - $StartTime)))]"
