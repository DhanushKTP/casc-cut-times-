<#
  Registers the sync to run every 2 minutes on this PC, for the logged-in user.
  Run once, from this folder:  powershell -ExecutionPolicy Bypass -File install-task.ps1
  Remove it later with:        Unregister-ScheduledTask -TaskName 'CASC Cut Times sync' -Confirm:$false
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'CascCutTimeSync.ps1'
if (-not (Test-Path (Join-Path $here 'config.json'))) { throw 'Create config.json first (copy config.example.json).' }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"" -WorkingDirectory $here
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
  -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

Register-ScheduledTask -TaskName 'CASC Cut Times sync' -Action $action -Trigger @($trigger, $logon) -Settings $settings `
  -Description 'Sends SigmaNEST programs to the CASC Cut Times tablet app every 2 minutes.' -Force | Out-Null
Write-Host "Installed. It runs every 2 minutes while you're logged in. Logs: $here\logs"
