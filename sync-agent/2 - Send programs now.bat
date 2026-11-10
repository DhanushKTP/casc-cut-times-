@echo off
title CASC Cut Times - send programs now
cd /d "%~dp0"
echo Sending SigmaNEST programs to the app. The first time it goes back to 1 Jan, so give it a few minutes...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CascCutTimeSync.ps1" -Force
echo.
if errorlevel 1 (echo FAILED - the reason is on the ERROR line above.) else (echo Done. Open the app on the tablet: the programs should be there.)
echo.
pause
