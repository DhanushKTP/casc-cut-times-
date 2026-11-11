# Creates the scheduled task "CASC Cut Times sync": every 2 minutes, 06:00-18:00, Monday to Friday,
# for the logged-in Windows user. It runs hidden (no window popping up), wakes the PC from sleep to run,
# runs on battery and catches up a missed run as soon as it can.
param([string]$TaskName = 'CASC Cut Times sync', [string]$At = '06:00')
$ErrorActionPreference = 'Stop'
$name = $TaskName
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Test-Path (Join-Path $here 'config.json'))) { throw 'Run "1 - Set up and test.bat" first.' }
$vbs = Join-Path $here 'run-hidden.vbs'

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbs) -WorkingDirectory $here
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $At
$every2 = New-ScheduledTaskTrigger -Once -At $At -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Hours 12)
$trigger.Repetition = $every2.Repetition
$settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force `
  -Description 'Sends SigmaNEST programs to the CASC cut times app (read-only).' | Out-Null

Write-Host "Done. '$name' runs every 2 minutes, $At-18:00, Monday to Friday, while this PC is on."
Write-Host 'Each run adds a line to sync_log.txt in this folder. "Check cut times sync.bat" shows how it is doing.'
