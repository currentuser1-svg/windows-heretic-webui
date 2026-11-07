@echo off
setlocal
rem Stop everything.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stop.ps1"  %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Failed with code %RC%. Read the messages above. Logs: C:\llama\logs
  pause
  exit /b %RC%
)
timeout /t 3 >nul
exit /b 0
