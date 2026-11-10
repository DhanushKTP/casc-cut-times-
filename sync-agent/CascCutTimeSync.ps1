<#
  CASC Cut Times - SigmaNEST sync
  Reads SigmaNEST (SNDBase) READ-ONLY and sends the program list to the cut-times app.
  Needs nothing installed: Windows PowerShell 5.1 and .NET's built-in SQL client.

  Each run:
    1. Programs waiting in SigmaNEST (dbo.Program): sent when the list has changed, and at least
       every 8 minutes anyway so the tablet can see the PC is still syncing.
    2. Programs completed in SigmaNEST (dbo.ProgArchive, TransType SN102) since the last run, sent only
       when something new has been completed. The first run goes back to StartDate, a month at a time.

  Safe by design: SELECT queries only, on a read-only connection that never locks SigmaNEST's tables.

  Usage:  CascCutTimeSync.ps1            normal run (what the scheduled task does)
          CascCutTimeSync.ps1 -Force     send everything now, even if nothing changed
          CascCutTimeSync.ps1 -Test      check SQL and the website only, send nothing
#>
param([switch]$Test, [switch]$Force)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $here 'config.json'
$statePath = Join-Path $here 'state.json'
$logFile = Join-Path $here 'sync_log.txt'
$HeartbeatMinutes = 8

function Write-Log([string]$msg) {
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try {
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
      Move-Item $logFile (Join-Path $here 'sync_log.old.txt') -Force
    }
    Add-Content -Path $logFile -Value $line
  } catch { }
  Write-Host $line
}

if (-not (Test-Path $configPath)) { throw 'config.json not found. Run "1 - Set up and test.bat" first.' }
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json
foreach ($k in 'SqlServer', 'Database', 'SiteUrl', 'StartDate') {
  if (-not $cfg.$k) { throw "config.json: '$k' is empty." }
}

# The sync key is stored encrypted for this Windows user (DPAPI). A plain SyncKey also works.
function Get-SyncKey {
  if ($cfg.SyncKeyEncrypted) {
    $sec = ConvertTo-SecureString $cfg.SyncKeyEncrypted
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  }
  if ($cfg.SyncKey) { return [string]$cfg.SyncKey }
  throw 'No sync key saved. Run "1 - Set up and test.bat" again.'
}
$syncKey = Get-SyncKey
$batchSize = if ($cfg.BatchSize) { [int]$cfg.BatchSize } else { 300 }
$site = $cfg.SiteUrl.TrimEnd('/')
if ($site -notmatch '^https://') { throw "SiteUrl must start with https:// (it is $site)." }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------------------------------------------------------ SQL (read-only)

function New-Connection {
  $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
  $b['Data Source'] = $cfg.SqlServer
  $b['Initial Catalog'] = $cfg.Database
  $b['Application Name'] = 'CASC Cut Times sync'
  $b['ApplicationIntent'] = 'ReadOnly'
  $b['Connect Timeout'] = 15
  if ($cfg.UseWindowsAuth -eq $false) {
    $b['User ID'] = $cfg.SqlUser
    $b['Password'] = $cfg.SqlPassword
  } else {
    $b['Integrated Security'] = $true
  }
  $c = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
  $c.Open()
  # Never hold SigmaNEST up: read without taking locks.
  $cmd = $c.CreateCommand()
  $cmd.CommandText = 'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED'
  [void]$cmd.ExecuteNonQuery()
  return $c
}

function Invoke-Query($conn, [string]$sql, [hashtable]$params = @{}) {
  if ($sql.TrimStart() -notmatch '^SELECT') { throw 'Read-only queries only.' }
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = $sql
  $cmd.CommandTimeout = 300
  foreach ($k in $params.Keys) { [void]$cmd.Parameters.AddWithValue($k, $params[$k]) }
  $table = New-Object System.Data.DataTable
  $reader = $cmd.ExecuteReader()
  $table.Load($reader)
  $reader.Close()
  return , $table
}

function Iso($v) {
  if ($v -is [DBNull] -or $null -eq $v) { return $null }
  return ([datetime]$v).ToString('yyyy-MM-ddTHH:mm:ss')
}
function Num($v) { if ($v -is [DBNull] -or $null -eq $v) { return $null } return [double]$v }
function Str($v) { if ($v -is [DBNull] -or $null -eq $v) { return '' } return ([string]$v).Trim() }

# Customer comes from the open work order, or the archived one once it's closed.
# Next op is Part.Data1 ("Fold", "Dispatch", ...), or the archived part's Data1.
$customerSql = @'
COALESCE(w.CustomerName, (SELECT TOP 1 wa.CustomerName FROM dbo.WOArchive wa WHERE wa.WONumber = x.WONumber ORDER BY wa.AutoID DESC))
'@
$nextOpSql = @'
COALESCE(pt.Data1, (SELECT TOP 1 pa.Data1 FROM dbo.PartArchive pa WHERE pa.WoNumber = x.WONumber AND pa.PartName = x.PartName ORDER BY pa.AutoID DESC))
'@

$waitingProgramsSql = @'
SELECT ProgramName, RepeatID, MachineName, Material, Thickness, SheetName, SheetLength, SheetWidth,
       CuttingTime, PostDateTime, ScrapFraction
FROM dbo.Program
ORDER BY ProgramName, RepeatID
'@

$waitingPartsSql = @"
SELECT x.ProgramName, x.RepeatID, x.WONumber, x.PartName, x.QtyInProcess, x.TotalCuttingTime,
       $customerSql AS CustomerName,
       $nextOpSql AS NextOp
FROM dbo.PIP x
LEFT JOIN dbo.Wo w ON w.WONumber = x.WONumber
LEFT JOIN dbo.Part pt ON pt.WONumber = x.WONumber AND pt.PartName = x.PartName
WHERE x.RepeatID = (SELECT MIN(y.RepeatID) FROM dbo.PIP y WHERE y.ProgramName = x.ProgramName)
"@

$doneProgramsSql = @'
SELECT a.ProgramName, a.RepeatID, a.MachineName, a.Taskname, a.SheetName, a.CuttingTime,
       a.PostDateTime, a.CompDate, a.ScrapFraction, a.ArchivePacketID
FROM dbo.ProgArchive a
WHERE a.TransType = 'SN102' AND a.CompDate >= @since AND a.CompDate < @until
ORDER BY a.ProgramName, a.RepeatID
'@

$donePartsSql = @"
SELECT x.ProgramName, x.RepeatID, x.ArchivePacketID, x.WONumber, x.PartName, x.QtyInProcess, x.TotalCuttingTime,
       $customerSql AS CustomerName,
       $nextOpSql AS NextOp
FROM dbo.PIPArchive x
JOIN dbo.ProgArchive a ON a.ProgramName = x.ProgramName AND a.RepeatID = x.RepeatID
     AND a.ArchivePacketID = x.ArchivePacketID AND a.TransType = 'SN102'
LEFT JOIN dbo.Wo w ON w.WONumber = x.WONumber
LEFT JOIN dbo.Part pt ON pt.WONumber = x.WONumber AND pt.PartName = x.PartName
WHERE x.TransType = 'SN102' AND a.CompDate >= @since AND a.CompDate < @until
"@

# ---------------------------------------------------------- build programs

function New-Part($r) {
  [ordered]@{
    part       = Str $r.PartName
    qty        = [int](Num $r.QtyInProcess)
    op         = Str $r.NextOp
    wo         = Str $r.WONumber
    customer   = Str $r.CustomerName
    plannedSec = [math]::Round((Num $r.TotalCuttingTime), 1)
  }
}

function Build-Waiting($progRows, $partRows) {
  $parts = @{}
  foreach ($r in $partRows) {
    $k = Str $r.ProgramName
    if (-not $parts.ContainsKey($k)) { $parts[$k] = New-Object System.Collections.ArrayList }
    [void]$parts[$k].Add((New-Part $r))
  }
  $byProg = [ordered]@{}
  foreach ($r in $progRows) {
    $k = Str $r.ProgramName
    if ($byProg.Contains($k)) { $byProg[$k]['sheets'] = $byProg[$k]['sheets'] + 1; continue }
    $scrap = Num $r.ScrapFraction
    # Assign the list directly: piping it through an if/else would turn 0 or 1 parts into null/an object.
    $plist = $parts[$k]
    if ($null -eq $plist) { $plist = New-Object System.Collections.ArrayList }
    $byProg[$k] = [ordered]@{
      no         = $k
      machine    = Str $r.MachineName
      material   = Str $r.Material
      thickness  = Num $r.Thickness
      sheet      = Str $r.SheetName
      sheetL     = Num $r.SheetLength
      sheetW     = Num $r.SheetWidth
      plannedSec = [math]::Round((Num $r.CuttingTime), 1)
      sheets     = 1
      scrapPct   = if ($null -ne $scrap) { [math]::Round($scrap * 100, 1) } else { $null }
      posted     = Iso $r.PostDateTime
      completed  = $null
      parts      = $plist
    }
  }
  return @($byProg.Values)
}

function Build-Done($progRows, $partRows) {
  # Parts belong to the first repeat's archive packet.
  $parts = @{}
  foreach ($r in $partRows) {
    $k = "{0}|{1}|{2}" -f (Str $r.ProgramName), $r.RepeatID, $r.ArchivePacketID
    if (-not $parts.ContainsKey($k)) { $parts[$k] = New-Object System.Collections.ArrayList }
    [void]$parts[$k].Add((New-Part $r))
  }
  $byProg = [ordered]@{}
  foreach ($r in $progRows) {
    $k = Str $r.ProgramName
    $comp = Iso $r.CompDate
    if ($byProg.Contains($k)) {
      $byProg[$k]['sheets'] = $byProg[$k]['sheets'] + 1
      if ($comp -gt $byProg[$k]['completed']) { $byProg[$k]['completed'] = $comp }
      continue
    }
    # Taskname looks like "MS-S275_4mm" -> material "MS-S275", thickness 4
    $task = Str $r.Taskname
    $material = $task; $thick = $null
    if ($task -match '^(.*)_([\d.]+)mm$') { $material = $Matches[1]; $thick = [double]$Matches[2] }
    $pk = "{0}|{1}|{2}" -f $k, $r.RepeatID, $r.ArchivePacketID
    $scrap = Num $r.ScrapFraction
    $plist = $parts[$pk]
    if ($null -eq $plist) { $plist = New-Object System.Collections.ArrayList }
    $byProg[$k] = [ordered]@{
      no         = $k
      machine    = Str $r.MachineName
      material   = $material
      thickness  = $thick
      sheet      = Str $r.SheetName
      sheetL     = $null
      sheetW     = $null
      plannedSec = [math]::Round((Num $r.CuttingTime), 1)
      sheets     = 1
      scrapPct   = if ($null -ne $scrap) { [math]::Round($scrap * 100, 1) } else { $null }
      posted     = Iso $r.PostDateTime
      completed  = $comp
      parts      = $plist
    }
  }
  return @($byProg.Values)
}

# ------------------------------------------------------------------ send

function ConvertTo-ProgramsJson($programs) {
  $list = New-Object System.Collections.ArrayList
  foreach ($p in @($programs)) { [void]$list.Add($p) }
  return (ConvertTo-Json -InputObject $list -Depth 6 -Compress)
}

function Get-Fingerprint([string]$text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '')
}

function Send-Sync([string]$kind, $programs) {
  $json = '{"kind":"' + $kind + '","programs":' + (ConvertTo-ProgramsJson $programs) + '}'
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  try {
    $res = Invoke-RestMethod -Uri "$site/api/sync" -Method Post -Body $bytes `
      -ContentType 'application/json; charset=utf-8' -Headers @{ 'x-sync-key' = $syncKey } -TimeoutSec 60
  } catch {
    $detail = $_.ErrorDetails.Message
    if (-not $detail) { $detail = $_.Exception.Message }
    throw "the site refused the $kind upload: $detail"
  }
  if (-not $res.ok) { throw "the site refused the $kind upload: $($res.error)" }
  return $res
}

function Read-State {
  $s = [ordered]@{ doneSince = $null; waitingFp = $null; waitingAt = $null; doneFp = $null }
  if (Test-Path $statePath) {
    $f = Get-Content $statePath -Raw | ConvertFrom-Json
    foreach ($k in @($s.Keys)) { if ($f.$k) { $s[$k] = $f.$k } }
  }
  return $s
}
function Save-State($s) { $s | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8 }

# ------------------------------------------------------------------- run

$conn = $null
try {
  $t0 = Get-Date
  $conn = New-Connection

  if ($Test) {
    $n = (Invoke-Query $conn 'SELECT COUNT(*) AS n FROM dbo.Program').Rows[0].n
    Write-Log "SQL OK: $($cfg.SqlServer) / $($cfg.Database), $n program rows waiting in SigmaNEST."
    try {
      $ping = Invoke-RestMethod -Uri "$site/api/sync" -Method Post -Body '{"kind":"ping"}' -ContentType 'application/json' -Headers @{ 'x-sync-key' = $syncKey } -TimeoutSec 30
      Write-Log "Site OK: $site accepted the sync key (site time $($ping.at))."
    } catch {
      $detail = $_.ErrorDetails.Message
      if (-not $detail) { $detail = $_.Exception.Message }
      throw "the site didn't accept the connection or the sync key: $detail"
    }
    return
  }

  $state = Read-State
  $sent = @()

  # 1. Waiting programs.
  $wp = Invoke-Query $conn $waitingProgramsSql
  $wparts = Invoke-Query $conn $waitingPartsSql
  $waiting = @(Build-Waiting $wp.Rows $wparts.Rows)
  $wfp = Get-Fingerprint (ConvertTo-ProgramsJson $waiting)
  $age = if ($state.waitingAt) { ((Get-Date) - [datetime]$state.waitingAt).TotalMinutes } else { 9999 }
  if ($Force -or $wfp -ne $state.waitingFp -or $age -ge $HeartbeatMinutes) {
    $r = Send-Sync 'waiting' $waiting
    $state.waitingFp = $wfp
    $state.waitingAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    Save-State $state
    $sent += "waiting ($($r.count))"
  }

  # 2. Completed programs since the last run (a day of overlap catches late archiving; the site updates in place).
  $start = [datetime]::ParseExact($cfg.StartDate, 'yyyy-MM-dd', $null)
  $firstRun = -not $state.doneSince
  $since = if ($state.doneSince) { ([datetime]$state.doneSince).AddDays(-1) } else { $start }
  if ($since -lt $start) { $since = $start }
  $now = Get-Date

  $from = $since
  $windowFp = ''
  $doneCount = 0
  $chunks = New-Object System.Collections.ArrayList
  while ($from -lt $now) {
    $to = $from.AddMonths(1); if ($to -gt $now.AddMinutes(1)) { $to = $now.AddMinutes(1) }
    $p = @{ '@since' = $from; '@until' = $to }
    $dp = Invoke-Query $conn $doneProgramsSql $p
    if ($dp.Rows.Count -gt 0) {
      $dparts = Invoke-Query $conn $donePartsSql $p
      $done = @(Build-Done $dp.Rows $dparts.Rows)
      $doneCount += $done.Count
      [void]$chunks.Add(@{ from = $from; to = $to; programs = $done })
      $windowFp += Get-Fingerprint (ConvertTo-ProgramsJson $done)
    }
    $from = $to
  }
  $dfp = Get-Fingerprint $windowFp
  if ($doneCount -gt 0 -and ($Force -or $firstRun -or $dfp -ne $state.doneFp)) {
    $total = 0
    foreach ($c in $chunks) {
      $done = $c.programs
      for ($i = 0; $i -lt $done.Count; $i += $batchSize) {
        $chunk = $done[$i..([math]::Min($i + $batchSize, $done.Count) - 1)]
        $res = Send-Sync 'done' $chunk
        $total += $res.count
      }
      if ($firstRun) { Write-Log ("  completed {0:dd/MM/yyyy} to {1:dd/MM/yyyy}: {2} programs" -f $c.from, $c.to, $c.programs.Count) }
    }
    $sent += "completed ($total)"
  }
  $state.doneFp = $dfp
  $state.doneSince = $now.ToString('yyyy-MM-ddTHH:mm:ss')
  Save-State $state

  $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  $summary = "read SigmaNEST in $secs s: $($waiting.Count) waiting, $doneCount completed since $($since.ToString('dd/MM HH:mm'))"
  if ($sent.Count) { Write-Log "$summary; sent $($sent -join ', ')" } else { Write-Log "$summary; no change, nothing sent" }
}
catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  exit 1
}
finally {
  if ($conn) { $conn.Close() }
}
