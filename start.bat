@echo off
setlocal
rem Start llama-server and Open WebUI.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start.ps1"  %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Failed with code %RC%. Read the messages above. Logs: C:\llama\logs
  pause
  exit /b %RC%
)
timeout /t 5 >nul
exit /b 0
