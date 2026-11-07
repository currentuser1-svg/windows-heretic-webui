@echo off
setlocal
rem One button: llama.cpp + model + Open WebUI. Safe to run again.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1"  %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Failed with code %RC%. Read the messages above. Logs: C:\llama\logs
  pause
  exit /b %RC%
)
pause
exit /b 0
