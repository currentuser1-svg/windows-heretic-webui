@echo off
setlocal
rem Update llama.cpp and Open WebUI, keep model and chats.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" -Update -NoStart %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Failed with code %RC%. Read the messages above. Logs: C:\llama\logs
  pause
  exit /b %RC%
)
pause
exit /b 0
