@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
echo ============================================================
echo 移除 MiniMax H3 Heretic 专用工作流
echo 官方 MiniMax_H3_8GB.json 不会被修改或删除
echo ============================================================
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Isolated-v2.ps1" -Rollback
set "EC=%ERRORLEVEL%"
echo.
pause
exit /b %EC%
