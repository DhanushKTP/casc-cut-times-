@echo off
title CASC Cut Times - check sync
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_sync.ps1"
echo.
pause
