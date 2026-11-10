<#
  CASC Cut Times - SigmaNEST sync
  Reads SigmaNEST (SNDBase) READ-ONLY and sends the program list to the Netlify app.
  Runs every 2 minutes from Task Scheduler (see install-task.ps1). Needs nothing installed:
  Windows PowerShell 5.1 and .NET's built-in SQL client are enough.

  Each run:
    1. Sends every program waiting in SigmaNEST (dbo.Program).
    2. Sends programs completed in SigmaNEST (dbo.ProgArchive, TransType SN102) since the last run.
       The first run goes back to StartDate in config.json, in batches.

  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File CascCutTimeSync.ps1 [-Test]
          -Test only checks the SQL connection and the site, and sends nothing.
#>
param([switch]$Test)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $here 'config.json'
$statePath = Join-Path $here 'state.json'
$logDir = Join-Path $here 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("sync-{0}.log" -f (Get-Date -Format 'yyyy-MM'))

function Write-Log([string]$msg) {
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $logFile -Value $line
  Write-Host $line
}

if (-not (Test-Path $configPath)) { throw "config.json not found. Copy config.example.json to config.json and fill it in." }
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json
foreach ($k in 'SqlServer', 'Database', 'SiteUrl', 'SyncKey', 'StartDate') {
  if (-not $cfg.$k) { throw "config.json: '$k' is empty." }
}
$batchSize = if ($cfg.BatchSize) { [int]$cfg.BatchSize } else { 300 }
$site = $cfg.SiteUrl.TrimEnd('/')

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------------------------------------------------------ SQL

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
  return $c
}

function Invoke-Query($conn, [string]$sql, [hashtable]$params = @{}) {
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

function Send-Sync([string]$kind, $programs) {
  $list = New-Object System.Collections.ArrayList
  foreach ($p in @($programs)) { [void]$list.Add($p) }
  $payload = @{ kind = $kind; programs = $list }
  $json = ConvertTo-Json -InputObject $payload -Depth 6 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $res = Invoke-RestMethod -Uri "$site/api/sync" -Method Post -Body $bytes `
    -ContentType 'application/json; charset=utf-8' -Headers @{ 'x-sync-key' = $cfg.SyncKey } -TimeoutSec 60
  if (-not $res.ok) { throw "Site refused the $kind sync: $($res.error)" }
  return $res
}

function Read-State {
  if (Test-Path $statePath) { return (Get-Content $statePath -Raw | ConvertFrom-Json) }
  return [pscustomobject]@{ doneSince = $null }
}
function Save-State($s) { $s | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8 }

# ------------------------------------------------------------------- run

$conn = $null
try {
  $conn = New-Connection

  if ($Test) {
    $n = (Invoke-Query $conn 'SELECT COUNT(*) AS n FROM dbo.Program').Rows[0].n
    Write-Log "SQL OK: $n program rows waiting in SigmaNEST."
    $ping = Invoke-RestMethod -Uri "$site/api/sync" -Method Post -Body '{"kind":"ping"}' -ContentType 'application/json' -Headers @{ 'x-sync-key' = $cfg.SyncKey }
    Write-Log "Site OK: $site answered at $($ping.at)."
    return
  }

  # 1. Waiting programs: the whole list every time.
  $wp = Invoke-Query $conn $waitingProgramsSql
  $wparts = Invoke-Query $conn $waitingPartsSql
  $waiting = @(Build-Waiting $wp.Rows $wparts.Rows)
  $r = Send-Sync 'waiting' $waiting
  Write-Log "Waiting: sent $($r.count) programs."

  # 2. Completed programs since the last run (a day of overlap is harmless: the site updates in place).
  $state = Read-State
  $start = [datetime]::ParseExact($cfg.StartDate, 'yyyy-MM-dd', $null)
  $since = if ($state.doneSince) { ([datetime]$state.doneSince).AddDays(-1) } else { $start }
  if ($since -lt $start) { $since = $start }
  $now = Get-Date

  # Work through it a month at a time so the first run (back to StartDate) stays small.
  $from = $since
  while ($from -lt $now) {
    $to = $from.AddMonths(1); if ($to -gt $now.AddMinutes(1)) { $to = $now.AddMinutes(1) }
    $p = @{ '@since' = $from; '@until' = $to }
    $dp = Invoke-Query $conn $doneProgramsSql $p
    if ($dp.Rows.Count -gt 0) {
      $dparts = Invoke-Query $conn $donePartsSql $p
      $done = @(Build-Done $dp.Rows $dparts.Rows)
      for ($i = 0; $i -lt $done.Count; $i += $batchSize) {
        $chunk = $done[$i..([math]::Min($i + $batchSize, $done.Count) - 1)]
        $res = Send-Sync 'done' $chunk
        Write-Log ("Completed {0:dd/MM/yyyy}-{1:dd/MM/yyyy}: sent {2} programs." -f $from, $to, $res.count)
      }
    }
    $from = $to
  }
  $state.doneSince = $now.ToString('yyyy-MM-ddTHH:mm:ss')
  Save-State $state
}
catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  exit 1
}
finally {
  if ($conn) { $conn.Close() }
}
