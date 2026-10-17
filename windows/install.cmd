@echo off
rem 双击即可安装（会依次问你要 Mac 的地址）
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
