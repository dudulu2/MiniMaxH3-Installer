@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
echo ============================================================
echo MiniMax H3 Heretic 独立工作流安装器 v2
echo.
echo - 官方 MiniMax_H3_8GB.json 完全不修改
echo - 新增 Heretic 文生视频 T2V
echo - 新增 Heretic 图生视频 I2V
echo - hf-mirror 镜像优先，失败回退 Hugging Face 官方源
echo ============================================================
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Isolated-v2.ps1"
set "EC=%ERRORLEVEL%"
echo.
if not "%EC%"=="0" (
  echo 配置未完成，错误代码：%EC%
) else (
  echo 配置完成。
)
echo.
pause
exit /b %EC%
