@echo off
title CASC Cut Times - turn on automatic sync
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-task.ps1"
echo.
pause
