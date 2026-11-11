@echo off
title CASC Cut Times - check tube sync
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_sync.ps1" -TaskName "CASC Cut Times tube sync"
echo.
pause
