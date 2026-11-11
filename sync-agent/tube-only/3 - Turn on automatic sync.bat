@echo off
title CASC Cut Times - turn on automatic tube sync
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-task.ps1" -TaskName "CASC Cut Times tube sync" -At 06:01
echo.
pause
