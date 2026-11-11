# Asks for the SigmaNEST SQL details and the sync key once, saves them (the key encrypted for this
# Windows user), then tests reading SigmaNEST and reaching the website. Sends no data.
param([switch]$TubeOnly)   # -TubeOnly: set up the tube-laser-only copy of the sync
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $here 'config.json'

function Ask([string]$q, [string]$default) {
  $a = Read-Host "$q [$default]"
  if ([string]::IsNullOrWhiteSpace($a)) { return $default } else { return $a.Trim() }
}

Write-Host ''
if ($TubeOnly) { Write-Host 'CASC Cut Times - tube laser sync: set up' -ForegroundColor Cyan }
else { Write-Host 'CASC Cut Times - SigmaNEST sync: set up' -ForegroundColor Cyan }
if (Test-Path $configPath) {
  $again = Ask 'Settings are already saved. Enter them again? (Y/N)' 'N'
}
if (-not (Test-Path $configPath) -or $again -match '^[Yy]') {
  Write-Host 'Press Enter to keep the value in [brackets].'
  if ($TubeOnly) { Write-Host 'SigmaNEST is only used to find the customer for a JN when the tube file does not say. Type - to skip it.' }
  $server = Ask 'SQL Server' 'CASC-APPSRV-02\SIGMANEST'
  if ($server -eq '-') { $server = '' }
  $db = Ask 'Database' 'SNDBase'
  $site = Ask 'Website' 'https://casc-cut-times.netlify.app'
  $tube = Ask $(if ($TubeOnly) { 'Tube laser folder' } else { 'Tube laser folder (type - for none)' }) 'S:\TruLaser7000'
  if ($tube -eq '-' -and -not $TubeOnly) { $tube = '' }
  elseif ($tube -match '^([A-Za-z]):(.*)$') {
    # A mapped drive letter may not exist for the scheduled task: store the network path instead.
    $drive = Get-PSDrive -Name $Matches[1] -ErrorAction SilentlyContinue
    if ($drive -and $drive.DisplayRoot -like '\\*') { $tube = $drive.DisplayRoot.TrimEnd('\') + $Matches[2]; Write-Host "  Using the network path $tube" }
  }
  if ($tube -and -not (Test-Path $tube)) { Write-Host "  Warning: $tube can't be reached from this PC right now." -ForegroundColor Yellow }
  $sec = Read-Host 'Sync key (the SYNC_KEY set in Netlify; nothing shows as you type)' -AsSecureString
  if ($sec.Length -eq 0) { throw 'The sync key is needed.' }
  $cfg = [ordered]@{
    SqlServer        = $server
    Database         = $db
    UseWindowsAuth   = $true
    SqlUser          = ''
    SqlPassword      = ''
    SiteUrl          = $site
    SyncKeyEncrypted = (ConvertFrom-SecureString $sec)   # Windows DPAPI: only this user on this PC can read it
    TubeFolder       = $tube
    TubeOnly         = [bool]$TubeOnly
    StartDate        = '2026-01-01'
    BatchSize        = 300
  }
  $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
  Write-Host 'Saved. The sync key is stored encrypted for your Windows user only.' -ForegroundColor Green
}

# Settings saved before the tube laser was added: ask for the folder only.
$saved = Get-Content $configPath -Raw | ConvertFrom-Json
if ($null -eq $saved.PSObject.Properties['TubeFolder']) {
  $tube = Ask 'Tube laser folder (type - for none)' 'S:\TruLaser7000'
  if ($tube -eq '-') { $tube = '' }
  elseif ($tube -match '^([A-Za-z]):(.*)$') {
    $drive = Get-PSDrive -Name $Matches[1] -ErrorAction SilentlyContinue
    if ($drive -and $drive.DisplayRoot -like '\\*') { $tube = $drive.DisplayRoot.TrimEnd('\') + $Matches[2]; Write-Host "  Using the network path $tube" }
  }
  $saved | Add-Member -NotePropertyName TubeFolder -NotePropertyValue $tube
  $saved | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
  Write-Host 'Saved the tube laser folder.' -ForegroundColor Green
}

Write-Host ''
Write-Host "Testing as Windows user $env:USERDOMAIN\$env:USERNAME ..." -ForegroundColor Cyan
powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'CascCutTimeSync.ps1') -Test
if ($LASTEXITCODE -ne 0) {
  Write-Host ''
  Write-Host 'Test FAILED: the reason is on the ERROR line above.' -ForegroundColor Red
  Write-Host 'Wrong server or key? Run this again and answer Y to enter the settings again.'
  exit 1
}
Write-Host ''
if ($TubeOnly) { Write-Host 'Test PASSED. Next: "2 - Send tube packages now.bat".' -ForegroundColor Green }
else { Write-Host 'Test PASSED. Next: "2 - Send programs now.bat".' -ForegroundColor Green }
