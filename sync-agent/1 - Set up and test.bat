@echo off
title CASC Cut Times - set up and test
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1"
echo.
pause
