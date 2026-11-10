@echo off
chcp 65001 >nul
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" -ServerFolder "%~1"
set "deployExit=%ERRORLEVEL%"
echo.
echo 按任意键关闭窗口。
pause >nul
exit /b %deployExit%
