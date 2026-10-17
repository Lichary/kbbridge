<#
    clip-test.ps1 — ClipboardBridge 自测（Windows 侧剪贴板通道）

    会临时改写剪贴板（结束时还原文本），并删除测试生成的临时文件。
    可以在 KBBridge 正常运行的同时跑 —— 写入带重试，能扛住并发争用。

    用法：
        powershell -ExecutionPolicy Bypass -File .\clip-test.ps1
    或直接双击 clip-test.cmd
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$csc  = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "找不到 csc.exe: $csc（需要 .NET Framework 4.x）" }

$exe = Join-Path $env:TEMP 'clip-test.exe'
& $csc /nologo /codepage:65001 /target:exe /main:KBBridge.ClipTest "/out:$exe" `
    /r:System.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    (Join-Path $root 'windows\ClipboardBridge.cs') (Join-Path $root 'tools\clip-test.cs')
if ($LASTEXITCODE -ne 0) { throw '编译失败' }

& $exe
exit $LASTEXITCODE
