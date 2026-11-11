@echo off
title CASC Cut Times - stop tube sync
schtasks /Delete /F /TN "CASC Cut Times tube sync"
echo The automatic tube sync is switched off. "3 - Turn on automatic sync.bat" switches it back on.
echo.
pause
