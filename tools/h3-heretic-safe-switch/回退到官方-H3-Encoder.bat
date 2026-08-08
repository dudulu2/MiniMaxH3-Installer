@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
echo ============================================================
echo MiniMax H3 回退到官方 Text Encoder
echo ============================================================
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Enable-H3-Heretic-Encoder.ps1" -Rollback
set "EC=%ERRORLEVEL%"
echo.
if not "%EC%"=="0" (
  echo 回退未完成，错误代码：%EC%
) else (
  echo 已回退到官方工作流。
)
echo.
pause
exit /b %EC%
