# Huntress-EDR-Health-API-Monitor
A monitoring script for RMMs for Huntress EDR

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