@echo off
title CASC Cut Times - stop sync
schtasks /Delete /F /TN "CASC Cut Times sync"
echo The automatic cut times sync is switched off. "3 - Turn on automatic sync.bat" switches it back on.
echo.
pause
