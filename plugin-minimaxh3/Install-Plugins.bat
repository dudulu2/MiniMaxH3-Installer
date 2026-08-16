@echo off
setlocal
cd /d "%~dp0"
title MiniMax H3 Plugin Installer - CUDA 13 / Torch 2.10

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-Runtime.ps1"
if errorlevel 1 goto :failed

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Plugins.ps1"
if errorlevel 1 goto :failed

echo.
echo Plugin installation completed successfully.
echo.
pause
exit /b 0

:failed
echo.
echo Plugin installation stopped. The protected MiniMax H3 runtime was not intentionally upgraded.
echo Review the message and log above.
echo.
pause
exit /b 1
