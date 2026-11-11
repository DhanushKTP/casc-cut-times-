@echo off
title CASC Cut Times - send tube packages now
cd /d "%~dp0"
echo Sending the tube laser packages to the app. The first time it reads everything since 1 Jan...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CascCutTimeSync.ps1" -Force
echo.
if errorlevel 1 (echo FAILED - the reason is on the ERROR line above.) else (echo Done. On the tablet, the Tube 7000 button should now be there.)
echo.
pause
