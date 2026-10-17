@echo off
rem 双击即可编译（本机 PowerShell 执行策略是 Restricted，所以这里显式绕过）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
pause
