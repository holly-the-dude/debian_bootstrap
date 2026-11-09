@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap_debian.ps1" %*
set "bootstrap_exit=%errorlevel%"
if not "%bootstrap_exit%"=="0" pause
exit /b %bootstrap_exit%
