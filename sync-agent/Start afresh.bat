@echo off
title CASC Cut Times - start afresh
cd /d "%~dp0"
echo START AFRESH empties the website completely:
echo   - the program lists (3030, 1040, Tube 7000)
echo   - all submitted times in the app (every program goes back to "Needs times")
echo   - all running stopwatches
echo Then it sends everything again from SigmaNEST and S:\TruLaser7000.
echo The master Excel on SharePoint is NOT touched: delete any test rows there yourself.
echo.
choice /M "Empty the website and start afresh"
if errorlevel 2 goto end
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CascCutTimeSync.ps1" -Reset
echo.
if errorlevel 1 (echo FAILED - the reason is on the ERROR line above.) else (echo Done. Refresh the app: it starts afresh.)
:end
echo.
pause
