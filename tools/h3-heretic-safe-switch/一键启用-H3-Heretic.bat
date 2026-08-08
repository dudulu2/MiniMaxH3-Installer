@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
echo ============================================================
echo MiniMax H3 Ultra-Heretic INT8 ConvRot 安全一键切换
echo 官方 encoder 不会删除；失败自动回退
echo ============================================================
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Enable-H3-Heretic-Encoder.ps1"
set "EC=%ERRORLEVEL%"
echo.
if not "%EC%"=="0" (
  echo 操作未完成，错误代码：%EC%
) else (
  echo 操作完成。
)
echo.
pause
exit /b %EC%
