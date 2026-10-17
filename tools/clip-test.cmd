@echo off
rem 编译并运行 ClipboardBridge 自测（会临时改写剪贴板，结束时还原文本）
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0clip-test.ps1"
echo.
pause
