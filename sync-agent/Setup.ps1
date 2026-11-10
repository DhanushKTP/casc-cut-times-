# Asks for the SigmaNEST SQL details and the sync key once, saves them (the key encrypted for this
# Windows user), then tests reading SigmaNEST and reaching the website. Sends no data.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $here 'config.json'

function Ask([string]$q, [string]$default) {
  $a = Read-Host "$q [$default]"
  if ([string]::IsNullOrWhiteSpace($a)) { return $default } else { return $a.Trim() }
}

Write-Host ''
Write-Host 'CASC Cut Times - SigmaNEST sync: set up' -ForegroundColor Cyan
if (Test-Path $configPath) {
  $again = Ask 'Settings are already saved. Enter them again? (Y/N)' 'N'
}
if (-not (Test-Path $configPath) -or $again -match '^[Yy]') {
  Write-Host 'Press Enter to keep the value in [brackets].'
  $server = Ask 'SQL Server' 'CASC-APPSRV-02\SIGMANEST'
  $db = Ask 'Database' 'SNDBase'
  $site = Ask 'Website' 'https://casc-cut-times.netlify.app'
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
    StartDate        = '2026-01-01'
    BatchSize        = 300
  }
  $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
  Write-Host 'Saved. The sync key is stored encrypted for your Windows user only.' -ForegroundColor Green
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
Write-Host 'Test PASSED. Next: "2 - Send programs now.bat".' -ForegroundColor Green
