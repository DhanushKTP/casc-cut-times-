# Shows whether the CASC Cut Times sync is running as it should.
$name = 'CASC Cut Times sync'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
Write-Host ''
if (-not $t) { Write-Host "The task '$name' isn't set up on this PC. Run '3 - Turn on automatic sync.bat'." }
else {
  $i = $t | Get-ScheduledTaskInfo; $now = Get-Date
  $ran = $i.LastRunTime.Year -ge 2000
  $p = @()
  if ($t.State -eq 'Disabled')                { $p += 'switched off' }
  if ($t.Settings.DisallowStartIfOnBatteries) { $p += "skips runs on battery (run '3 - Turn on automatic sync.bat' again)" }
  if (-not $t.Settings.WakeToRun)             { $p += "doesn't wake the PC (run '3 - Turn on automatic sync.bat' again)" }
  if (-not $ran)                              { $p += 'has never run' }
  elseif ($i.LastTaskResult -notin 0, 267009) { $p += "last run failed (code $($i.LastTaskResult))" }
  if (-not $i.NextRunTime)                    { $p += 'no next run scheduled' }
  $last = if ($ran) { '{0:ddd dd MMM HH:mm} ({1} min ago)' -f $i.LastRunTime, [int]($now - $i.LastRunTime).TotalMinutes } else { 'never' }
  $next = if ($i.NextRunTime) { '{0:ddd dd MMM HH:mm} (in {1} min)' -f $i.NextRunTime, [math]::Max(0, [int]($i.NextRunTime - $now).TotalMinutes) } else { '-' }
  if ($p) { Write-Host "STATUS:   PROBLEM - $($p -join '; ')" -ForegroundColor Red } else { Write-Host 'STATUS:   OK' -ForegroundColor Green }
  Write-Host "Last run: $last"
  Write-Host "Next run: $next"
  if ($ran -and $now.DayOfWeek -notin 'Saturday', 'Sunday' -and $now.Hour -ge 7 -and $now.Hour -lt 18 -and ($now - $i.LastRunTime).TotalMinutes -gt 10) {
    Write-Host '          The last run is over 10 minutes ago in working hours: runs are being missed (standby or sleep?).'
  }
}
Write-Host ''
Write-Host 'Standby / sleep today (the sync can only run in these gaps if the PC can wake itself):'
$ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 42, 107, 506, 507; StartTime = (Get-Date).Date } -ErrorAction SilentlyContinue | Sort-Object TimeCreated
if (-not $ev) { Write-Host '  none' }
foreach ($e in $ev) { $w = switch ($e.Id) { 42 { 'went to sleep' } 107 { 'woke up' } 506 { 'screen off - standby' } 507 { 'back on' } }; Write-Host ('  {0:HH:mm}  {1}' -f $e.TimeCreated, $w) }
Write-Host ''
$log = Join-Path $here 'sync_log.txt'
Write-Host 'Last lines of sync_log.txt:'
if (Test-Path $log) { Get-Content $log -Tail 10 | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (no log yet)' }
