# Requires -Version 5
<#
This script was originally written for Datto RMM, but has been structured to work with several different RMMs
just by making a custom function to replace Start-Diagnostic, End-Diagnostic and Write-Status. These three functions
generate the RMM specific output so the RMM can "see" the diagnostic output and the monitoring results. Other RMMs
likely follow a similar process for parsing script output.

This monitor script is a rewrite of an earlier Huntress EDR Health API monitoring script to remove dependency on 3rd 
party functions and designed to address several issues still present as of Huntress Agent version 0.14.146. There are 
still issues with the connectivity time stamps when waking from sleep, and there are instances where the huntmon service 
is not runnig. Huntmon is a kernel level service that cannot be directly interfaced, but can be restarted by restarting 
the rio service. The huntmon/rio service not running is currently a bug in the program that Huntress engineers are working 
on a fix.

The goal of this monitor is to identify instances where the Huntress EDR requires human interaction to fix issues with 
the Huntress EDR Agent. Some issues are recoverable by simply restarting the affected service, others by simply waiting 
a bit and allowing the connectivity status to catch up. For the connectivity issues when waking from sleep, the monitor 
is setup to track consecutive failures. As long as one "healthy" result is seen in the last X times checked, the monitor 
result will return a healthy status. This is to prevent false-postive alerts while waiting for the connectivity state to 
update when waking from sleep.
#>

## Configured parameters
# Monitoring interval in minutes. Recommend 15 or 30 minutes.
$MonitorInterval=30 # 15, 30

# Counter lifespan - Time in hours before a monitor alert is generated.
$AlertHours=3

# RegistryKey location - Used to track concecutive failures. An entry named "HuntressEDRMonitor" will be created under this key.
$MonitorRegKey="HKLM:\SOFTWARE\CentraStage"

# Restart huntmon - Automatically attempt to restart the huntmon/rio service if stopped. (EDR Bug)
$RestartHuntmon=$true # $true, $false

# Restart any service - Attempt to restart any service that is stopped. (Automatic Remediation)
$RestartService=$false # $true, $false

## End Confiured Parameters

function Start-Diagnostic {
    # Adds the details for generating the diagnostic information for the RMM. This needs to be customized for the RMM.
    write-output "<-Start Diagnostic->"
}
function Stop-Diagnostic {
    # Adds the details for generating the diagnostic information for the RMM. This needs to be customized for the RMM.
    write-output "<-End Diagnostic->"
}
function write-status {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Status,
        [switch]$alert
    )
    write-output "`nEDR State: $Status"
    Stop-Diagnostic
    write-output "<-Start Result->"
    write-output "EDR=$Status"
    write-output "<-End Result->"
    if ($alert.IsPresent) {
        exit 1
    }
    else {
        exit 0
    }
}

function Write-HealthAPI ($result){
        # This was created in part due to some issues with the connectivity data not displaying in the output 
        # when called by simply using "$result.connectivity". It fully displays now, but the function will need to
        # be modified whenever Huntress makes a change to the data in the API response.

        write-output "`nEDR Health API:"
        write-output "`nOverall Status: $($result.status)"
        write-output "`nServices:"
        write-output "`tagent   : $($result.services.agent)"
        write-output "`thuntmon : $($result.services.huntmon)"
        write-output "`trio     : $($result.services.rio)"
        write-output "`tupdater : $($result.services.updater)"
        write-output "`nVersions:"
        write-output "`tagent   : $($result.versions.agent)"
        write-output "`thuntmon : $($result.versions.huntmon)"
        write-output "`trio     : $($result.versions.rio)"
        write-output "`tupdater : $($result.versions.updater)"
        write-output "`nConnectivity:"
        write-output "`terrors   : $($result.connectivity.errors)"
        write-output "`tevents   : $($result.connectivity.events)"
        write-output "`tmod_time : $($result.connectivity.mod_time)"
        write-output "`tsurvey   : $($result.connectivity.survey)"
        write-output "`ttasks    : $($result.connectivity.tasks)"
        write-output "`tupdate   : $($result.connectivity.update)"
}


# Max concecutive count
$MaxCount=[math]::ceiling($AlertHours*60/$MonitorInterval)

# Start Diagnostic output for the RMM.
Start-Diagnostic

# Uninstall key in registry
$HuntressKey="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Huntress"

# If Huntress is not installed, exit out without an alert.
if (Test-Path $HuntressKey){
    # Key is present
    $HuntressVersion=Get-ItemPropertyValue -Path $HuntressKey -name "DisplayVersion"
}
else {
    write-status -Status "Not Installed"
}

# Check for version 0.14.146 or newer.
if ($HuntressVersion -lt [version]"0.14.146"){
    write-output "`nHuntress Agent not supported. Agent version 0.14.146 or newer is requierd."
    $Status="Not Supported"
    write-status -Status $Status
}
else {
    write-host "`nHuntress Agent version 0.14.146 or newer is installed."
}

# Make sure that Huntress Updater service is running before we attempt to query the API.
try {
    $UpdaterService=Get-Service -name HuntressUpdater -ErrorAction Stop
}
catch {
    write-output "ERROR: Could not query HuntressUpdater service. Is Huntress installed?"
    $Status="Updater Service not available"
    write-status -Status $Status -alert
}
# if the service is stopped, attempt to start it and wait 30 seconds for everything to fire up.
if ($UpdaterService.Status -eq 'Stopped'){
    write-output "`nHuntress Updater service is stopped. Attempting to start."
    Start-Service -Name HuntressUpdater
    start-sleep 30
    $UpdaterService=Get-Service -name HuntressUpdater
}

# It's possible that the service is still starting from initial power on.  Wait up to 30 seconds for the service to start.
$i=0
while (($UpdaterService.Status -ne "Running") -and ($i -lt 3)){
    Write-Output "`nWaiting 10 seconds for Huntress Updater service to start..."
    $i++
    start-sleep 10
    $UpdaterService=Get-Service -name HuntressUpdater
}
if ($UpdaterService.status -ne "Running"){
    Write-Output "ERROR: Huntress Updater service is not running. Current status is: $($UpdaterService.Status)."
    $Status="HuntressUpdater not running."
    write-status -Status $Status
}
if ($UpdaterService.Status -eq "Running"){
    write-output "`nHuntress Updater services is running."
}


# Try querying the EDR Health API.
try {
    write-output "`nQuerying EDR Health API..."
    $response=Invoke-RestMethod -Uri 'http://localhost:24799/health' -ErrorAction Stop
    Write-Output "`tAPI response received."
}
# If an error in the response is returned.
catch {
    write-output "ERROR: EDR Health API threw an error."
    $Status="API Error"
    write-status -Status $Status -alert
}
# If a blank response is recived.
if ($null -eq $response){
    write-output "ERROR: Blank response from EDR Agent."
    $Status="Health API Not Responding"
    write-status -Status $Status -alert
}
else {
    # EDR Helath API responding properly.
    
    if ($response.status -eq "healthy"){
        $Status="Healthy" # status is in all lower case.
        
        # Reset the EDR monitor count to the max value.
        try {
            New-ItemProperty -Path $MonitorRegKey -name "HuntressEDRMonitor" -value $MaxCount -PropertyType dword -ErrorAction Stop | Out-Null
        }
        catch {
            Set-ItemProperty -Path $MonitorRegKey -name "HuntressEDRMonitor" -value $MaxCount | Out-Null
        }

        # Dislpay the API results.
        write-HealthAPI $response

        # write the status and end the script.
        write-status -Status $Status
    }
    else {
        # Check for the services and attempt automatic remediation if possible and configured.
        $ServiceRemediation=$false
        if (($response.services.agent -ne "running") -and ($RestartService)){
            # Check if service exists, then try restarting the service.
            $ServiceAgent=Get-Service -Name HuntressAgent
            if ($null -eq $ServiceAgent){
                write-output "Huntress Agent Service not found."
                write-status -Status "Agent Service Missing"
            }
            else {
                Start-Service -Name HuntressAgent
                $ServiceRemediation=$true
            }
        }
        if (($response.services.rio -ne "running") -and ($RestartService)){
            # Check if service exists, then try restarting the service.
            $ServiceAgent=Get-Service -Name HuntressRio
            if ($null -eq $ServiceAgent){
                write-output "Huntress Rio Service not found."
                write-status -Status "Rio Service Missing"
            }
            else {
                Start-Service -Name HuntressRio
                $ServiceRemediation=$true
            }
        }
        if (($response.services.Updater -ne "running") -and ($RestartService)){
            # Check if service exists, then try restarting the service.
            $ServiceAgent=Get-Service -Name HuntressUpdater
            if ($null -eq $ServiceAgent){
                write-output "Huntress Updater Service not found."
                write-status -Status "Updater Service Missing"
            }
            else {
                Start-Service -Name HuntressUpdater
                $ServiceRemediation=$true
            }
        }
        
        # Attempt to automatically remediate instances of the hunmon or rio service not running.
        if ((($response.services.rio -ne "running") -or ($response.services.huntmon -ne "running")) -and ($RestartHuntmon)){
            Stop-Service -name HuntressRio
            Start-Sleep 5
            Start-Service -name HuntressRio
            $ServiceRemediation=$true
        }

        # Wait 15 seconds if service remediation has been performed.
        if ($ServiceRemediation){
            start-sleep 15
            
            # Refresh the EDR Health status as well.
                $response=Invoke-RestMethod -Uri 'http://localhost:24799/health' -ErrorAction Stop
                # If a blank response is ever received, or an error in the response is returned.
                if ($null -eq $response){
                    write-output "ERROR: Blank response from EDR Agent."
                    $Status="Health API Not Responding"
                    write-status -Status $Status -alert
                }
                else {
                    # If everything is good now, report as such.
                    if ($response.status -eq "healthy"){
                    $Status="Healthy"
                    
                    # Reset the EDR monitor count to the max value.
                    try {
                        New-ItemProperty -Path $MonitorRegKey -name "HuntressEDRMonitor" -value $MaxCount -PropertyType dword -ErrorAction Stop | Out-Null
                    }
                    catch {
                        Set-ItemProperty -Path $MonitorRegKey -name "HuntressEDRMonitor" -value $MaxCount | Out-Null
                    }

                    write-HealthAPI $response
                    
                    # write the status and end the script.
                    write-status -Status $Status
                    }
                }
        }

        # If the status is not showing as healthy at this point, then report the status and start the countdown.
        $Status=$response.status
        write-HealthAPI $response

        # Read the value. If one isn't present, the write the value.
        try {
            $currentEDRValue=Get-ItemPropertyValue -Path $MonitorRegKey -Name "HuntressEDRMonitor" -ErrorAction Stop
        }
        catch {
            New-ItemProperty -Path $MonitorRegKey -name "HuntressEDRMonitor" -value $MaxCount -PropertyType dword -ErrorAction Stop | Out-Null
            $currentEDRValue=$MaxCount
        }
        if ($MaxCount -le 0){
            $currentEDRValue=$currentEDRValue--
            try {
                New-ItemProperty -Path $MonitorRegKey -name "HuntressEDRMonitor" -value $currentEDRValue -PropertyType dword -ErrorAction Stop | Out-Null
            }
            catch {
                Set-ItemProperty -Path $MonitorRegKey -name "HuntressEDRMonitor" -value $currentEDRValue | Out-Null
            }
            write-status -Status $status -alert
        }
        else {
            $currentEDRValue=$currentEDRValue--
            try {
                New-ItemProperty -Path $MonitorRegKey -name "HuntressEDRMonitor" -value $currentEDRValue -PropertyType dword -ErrorAction Stop | Out-Null
            }
            catch {
                Set-ItemProperty -Path $MonitorRegKey -name "HuntressEDRMonitor" -value $currentEDRValue | Out-Null
            }
            write-status -Status $status
        }
    }
}