@echo off
setlocal
cd /d "%~dp0"
title MiniMax H3 Heretic Safe Switch
echo ============================================================
echo MiniMax H3 Heretic Safe Switch v2.1
echo - Official workflow will NOT be modified
echo - Adds Heretic T2V workflow
echo - Adds Heretic I2V workflow
echo - hf-mirror first, Hugging Face fallback
echo ============================================================
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Isolated-v2.ps1"
set "EC=%ERRORLEVEL%"
echo.
if not "%EC%"=="0" (
  echo Operation failed. Exit code: %EC%
) else (
  echo Operation completed.
)
echo.
pause
exit /b %EC%
