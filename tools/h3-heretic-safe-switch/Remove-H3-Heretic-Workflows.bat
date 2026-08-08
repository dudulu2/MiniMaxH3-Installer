@echo off
setlocal
cd /d "%~dp0"
title Remove H3 Heretic Workflows
echo ============================================================
echo Remove MiniMax H3 Heretic workflows
echo Official workflow will NOT be modified or deleted.
echo ============================================================
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Isolated-v2.ps1" -Rollback
set "EC=%ERRORLEVEL%"
echo.
if not "%EC%"=="0" (
  echo Rollback failed. Exit code: %EC%
) else (
  echo Heretic workflows removed.
)
echo.
pause
exit /b %EC%
