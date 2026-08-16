@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Plugins.ps1"
set "EC=%ERRORLEVEL%"
echo.
if not "%EC%"=="0" (
  echo Plugin installation failed. Review the error above.
) else (
  echo Plugin installation completed successfully.
)
echo.
pause
exit /b %EC%
