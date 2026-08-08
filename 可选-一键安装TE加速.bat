@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
echo ==============================================
echo   可选组件：TE-Speed MiniMax H3 加速
echo ==============================================
echo.
echo 这不是 MiniMax H3 必装组件。
echo 它会修改 ComfyUI 的 MiniMax H3 model.py，并自动建立回退备份。
echo 详细风险说明会随 TE 安装包一起提供。
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Install-Optional-TE.ps1"
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
