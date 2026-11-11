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
          CascCutTimeSync.ps1 -Reset     start afresh: empty the website (programs, submitted times,
                                         stopwatches), then send everything again
#>
param([switch]$Test, [switch]$Force, [switch]$Reset)

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
$TubeOnly = [bool]$cfg.TubeOnly   # tube-laser-only copy of the sync: no SigmaNEST programs, SQL only for customer names
$required = if ($TubeOnly) { @('SiteUrl', 'StartDate', 'TubeFolder') } else { @('SqlServer', 'Database', 'SiteUrl', 'StartDate') }
foreach ($k in $required) {
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
if ($site -notmatch '^https://' -and $site -notmatch '^http://localhost(:\d+)?$') { throw "SiteUrl must start with https:// (it is $site)." }

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

# ------------------------------------------------------------------ tube laser (TruLaser Tube 7000)
# Production packages (.TPP) saved under TubeFolder, e.g. S:\TruLaser7000\JN11000-11999\JN11929\*.TPP.
# Everything on the printed production package is inside the .TPP (it is XML with the NC programs).

function Get-TubeJn([string]$relPath) {
  $parts = $relPath -split '[\\/]'
  for ($i = $parts.Count - 2; $i -ge 0; $i--) {
    if ($parts[$i] -match '^(JN\d{4,6}(?:[-_ ][A-Z]{1,2}\b)?)') { return ($Matches[1].ToUpper() -replace '[_ ]', '-') }
  }
  if ($relPath -match '(JN\d{4,6}(?:-[A-Z]{1,2})?)') { return $Matches[1].ToUpper() }
  return ''
}

function Get-ProfileLabel([string]$job, [string]$jn) {
  $base = ($jn -split '-')[0]
  $t = $job -replace [regex]::Escape($jn), '' -replace [regex]::Escape($base), ''
  $t = $t -replace '(?i)point', '.' -replace '[_-]+', ' '
  return ($t -replace '\s+', ' ').Trim()
}

function Get-Seconds([string]$hms) {
  $p = ($hms -replace '\s', '') -split ':'
  if ($p.Count -ne 3) { return 0 }
  return [int]$p[0] * 3600 + [int]$p[1] * 60 + [int]$p[2]
}

function Read-TubePackage([string]$fullPath, [string]$relPath) {
  $s = [IO.File]::ReadAllText($fullPath)
  $rx = [Text.RegularExpressions.RegexOptions]::Singleline
  $job = if ($s -match 'JobName="([^"]+)"') { $Matches[1] } else { [IO.Path]::GetFileNameWithoutExtension($fullPath) }
  $raw = if ($s -match '<fmc:DesiredTubeLength unit="mm" value="([\d.]+)"') { [double]$Matches[1] } else { $null }

  # NC programs: name, machine time (s), drawing path, creator, profile
  $progs = @{}
  $creator = ''; $profile = ''; $customer = ''
  $blocks = $s -split 'BEGIN_EINRICHTEPLAN_INFO'
  for ($i = 1; $i -lt $blocks.Count; $i++) {
    $b = $blocks[$i]
    $m = [regex]::Match($b, "ZA,DA,1\s*\r?\nDA,(.*?)\r?\nC\r?\n", $rx)
    if (-not $m.Success) { continue }
    $da = $m.Groups[1].Value -replace '\r?\n\*\s*', ''
    $strs = [regex]::Matches($da, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value }
    if ($strs.Count -lt 4) { continue }
    $name = $strs[3]
    $sec = 0
    $tm = [regex]::Match($b, "INTERNAL_DATA',101,1,'','T','','([\d :]+)\[")
    if ($tm.Success) { $sec = Get-Seconds $tm.Groups[1].Value }
    $progs[$name] = $sec
    if (-not $customer) {
      $pm = [regex]::Match($b, "INTERNAL_DATA',290,1,'','T','',\s*\r?\n?\*?\s*'([^']+)'")
      if ($pm.Success -and $pm.Groups[1].Value -match '(?i)Customers v2\\([^\\]+)\\') { $customer = $Matches[1].Trim() }
    }
    if (-not $creator -and $b -match 'Creator: (\S+)') { $creator = $Matches[1] }
    if (-not $profile -and $b -match 'TC_TUBE_TECH\("([^"]+)"\)') { $profile = $Matches[1] }
  }

  # Program groups = tube types; production orders = how many times each tube type runs
  $groups = @{}
  foreach ($g in [regex]::Matches($s, '<fmc:ProgramGroup Name="([^"]+)".*?</fmc:ProgramGroup>', $rx)) {
    $list = New-Object System.Collections.ArrayList
    foreach ($pp in [regex]::Matches($g.Value, 'OrderValueText="([^"]+)" Quantity="(\d+)"')) {
      $pn = $pp.Groups[1].Value; $q = [int]$pp.Groups[2].Value
      $ps = if ($progs.ContainsKey($pn)) { $progs[$pn] } else { 0 }
      [void]$list.Add([ordered]@{ part = $pn; qty = $q; plannedSec = $ps })
    }
    $groups[$g.Groups[1].Value] = $list
  }
  $tubes = New-Object System.Collections.ArrayList
  $total = 0; $count = 0
  foreach ($o in [regex]::Matches($s, '<fmc:ProductionOrder DesiredQuantity="(\d+)" Name="[^"]+" OrderType="([^"]+)" OrderValueText="([^"]+)"')) {
    $runs = [int]$o.Groups[1].Value; $val = $o.Groups[3].Value
    $plist = $groups[$val]
    if ($null -eq $plist) {
      # an order straight on one program, not a group
      $plist = New-Object System.Collections.ArrayList
      $ps = if ($progs.ContainsKey($val)) { $progs[$val] } else { 0 }
      [void]$plist.Add([ordered]@{ part = $val; qty = 1; plannedSec = $ps })
    }
    $tsec = 0; foreach ($x in $plist) { $tsec += $x.qty * $x.plannedSec }
    [void]$tubes.Add([ordered]@{ group = $val; runs = $runs; plannedSec = $tsec; parts = $plist })
    $total += $runs * $tsec; $count += $runs
  }

  $jn = Get-TubeJn $relPath
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $id = 'T-' + ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($relPath.ToLowerInvariant()))).Replace('-', '').Substring(0, 12))
  return [ordered]@{
    no           = $id
    jn           = $jn
    customer     = $customer
    job          = $job
    file         = $relPath
    profile      = $profile
    profileLabel = Get-ProfileLabel $job $jn
    rawLength    = $raw
    plannedSec   = $total
    sheets       = [math]::Max(1, $count)
    programmedBy = $creator
    posted       = (Get-Item $fullPath).LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
    tubes        = $tubes
  }
}

# Customer by JN from SigmaNEST, for packages whose drawing path doesn't name one.
function Find-Customers($conn, $jns) {
  $out = @{}
  if (-not $conn -or -not $jns.Count) { return $out }
  $sql = @'
SELECT TOP 1 CustomerName FROM (
  SELECT CustomerName, 1 AS o FROM dbo.Wo WHERE WONumber = @jn OR WONumber LIKE @like
  UNION ALL
  SELECT CustomerName, 2 AS o FROM dbo.WOArchive WHERE WONumber = @jn OR WONumber LIKE @like
) x WHERE CustomerName IS NOT NULL AND CustomerName <> '' ORDER BY o
'@
  foreach ($jn in $jns) {
    $base = ($jn -split '-')[0]
    $t = Invoke-Query $conn $sql @{ '@jn' = $jn; '@like' = "$base%" }
    if ($t.Rows.Count) { $out[$jn] = Str $t.Rows[0].CustomerName }
  }
  return $out
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
  $s = [ordered]@{ doneSince = $null; waitingFp = $null; waitingAt = $null; doneFp = $null; tubeFiles = @{} }
  if (Test-Path $statePath) {
    $f = Get-Content $statePath -Raw | ConvertFrom-Json
    foreach ($k in @($s.Keys)) { if ($f.$k -and $k -ne 'tubeFiles') { $s[$k] = $f.$k } }
    if ($f.tubeFiles) { foreach ($p in $f.tubeFiles.PSObject.Properties) { $s.tubeFiles[$p.Name] = $p.Value } }
  }
  return $s
}
function Save-State($s) { $s | ConvertTo-Json -Depth 4 | Set-Content -Path $statePath -Encoding UTF8 }

# ------------------------------------------------------------------- run

$conn = $null
try {
  $t0 = Get-Date
  if ($TubeOnly) {
    # SigmaNEST is only used to look up customers for tube jobs; carry on without it if it can't be reached.
    if ($cfg.SqlServer) { try { $conn = New-Connection } catch { $conn = $null; if ($Test) { Write-Log "Note: SigmaNEST not reachable ($($_.Exception.Message)); customers will come from the drawing path only." } } }
  } else {
    $conn = New-Connection
  }

  if ($Test) {
    if ($conn) {
      $n = (Invoke-Query $conn 'SELECT COUNT(*) AS n FROM dbo.Program').Rows[0].n
      Write-Log "SQL OK: $($cfg.SqlServer) / $($cfg.Database), $n program rows waiting in SigmaNEST."
    }
    if ($cfg.TubeFolder) {
      if (Test-Path $cfg.TubeFolder) {
        $nt = @(Get-ChildItem -Path $cfg.TubeFolder -Recurse -File -Filter '*.tpp' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge [datetime]::ParseExact($cfg.StartDate, 'yyyy-MM-dd', $null) }).Count
        Write-Log "Tube folder OK: $($cfg.TubeFolder), $nt production packages since $($cfg.StartDate)."
      } else { throw "the tube folder $($cfg.TubeFolder) can't be reached from this PC." }
    }
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

  if ($Reset) {
    $res = Invoke-RestMethod -Uri "$site/api/sync" -Method Post -Body '{"kind":"reset","confirm":"CLEAR"}' -ContentType 'application/json' -Headers @{ 'x-sync-key' = $syncKey } -TimeoutSec 120
    Write-Log "Website emptied: programs, submitted times and stopwatches ($($res.removed) items removed). Sending everything again..."
    if (Test-Path $statePath) { Remove-Item $statePath -Force }
    $Force = $true
  }

  $state = Read-State
  $sent = @()

  $waiting = @(); $doneCount = 0; $since = Get-Date
  $start = [datetime]::ParseExact($cfg.StartDate, 'yyyy-MM-dd', $null)
  if (-not $TubeOnly) {
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
  }

  # 3. Tube laser packages: only files that are new or changed since the last run.
  $tubeNote = ''
  if ($cfg.TubeFolder) {
    if (-not (Test-Path $cfg.TubeFolder)) {
      Write-Log "WARNING: tube folder $($cfg.TubeFolder) can't be reached, tube packages skipped this run."
    } else {
      $root = (Resolve-Path $cfg.TubeFolder).ProviderPath.TrimEnd('\')
      $files = Get-ChildItem -Path $root -Recurse -File -Filter '*.tpp' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $start }
      $changed = New-Object System.Collections.ArrayList
      foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\')
        $stamp = $f.LastWriteTimeUtc.Ticks.ToString() + ':' + $f.Length
        if ($Force -or $state.tubeFiles[$rel] -ne $stamp) { [void]$changed.Add(@{ full = $f.FullName; rel = $rel; stamp = $stamp }) }
      }
      if ($changed.Count) {
        $packs = New-Object System.Collections.ArrayList
        $bad = 0
        foreach ($c in $changed) {
          try { [void]$packs.Add((Read-TubePackage $c.full $c.rel)) }
          catch { $bad++; Write-Log "  couldn't read $($c.rel): $($_.Exception.Message)" }
        }
        $need = @($packs | Where-Object { -not $_.customer -and $_.jn } | ForEach-Object { $_.jn } | Select-Object -Unique)
        $cust = Find-Customers $conn $need
        foreach ($p in $packs) { if (-not $p.customer -and $cust.ContainsKey($p.jn)) { $p.customer = $cust[$p.jn] } }
        $arr = @($packs)
        for ($i = 0; $i -lt $arr.Count; $i += 100) {
          $chunk = $arr[$i..([math]::Min($i + 100, $arr.Count) - 1)]
          [void](Send-Sync 'tube' $chunk)
        }
        foreach ($c in $changed) { $state.tubeFiles[$c.rel] = $c.stamp }
        Save-State $state
        $sent += "tube packages ($($arr.Count))"
        if ($bad) { $sent += "$bad unreadable" }
      }
      $tubeNote = ", $(@($files).Count) tube packages"
    }
  }

  # "Still here" for each source this run checked, so the tablet shows when each list was last checked.
  $checked = @()
  if (-not $TubeOnly) { $checked += 'sigma' }
  if ($cfg.TubeFolder -and $tubeNote) { $checked += 'tube' }
  if ($checked.Count) {
    try {
      $pingBody = '{"kind":"ping","sources":["' + ($checked -join '","') + '"]}'
      [void](Invoke-RestMethod -Uri "$site/api/sync" -Method Post -Body $pingBody -ContentType 'application/json' -Headers @{ 'x-sync-key' = $syncKey } -TimeoutSec 30)
    } catch { Write-Log "WARNING: couldn't send the 'still here' signal: $($_.Exception.Message)" }
  }

  $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  $summary = if ($TubeOnly) { "read in $secs s$tubeNote" } else { "read in $secs s: $($waiting.Count) waiting, $doneCount completed since $($since.ToString('dd/MM HH:mm'))$tubeNote" }
  if ($sent.Count) { Write-Log "$summary; sent $($sent -join ', ')" } else { Write-Log "$summary; no change, nothing sent" }
}
catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  exit 1
}
finally {
  if ($conn) { $conn.Close() }
}
