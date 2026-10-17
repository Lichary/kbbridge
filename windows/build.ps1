<#
    build.ps1 — 编译 KBBridge

    用系统自带的 .NET Framework 编译器 csc.exe，不下载任何东西、不装任何运行时。

    会产出两个 exe：
        KBBridge.exe          常驻代理（无窗口，带托盘图标）
        KBBridgeSettings.exe  设置窗口
    两个 exe 用同一套源码，靠 csc 的 /main: 选入口，进程名分开互不干扰
    （「保存并重启」要结束 KBBridge.exe，不能把自己也杀掉）。

    覆盖前会先结束「正要被覆盖的那两个 exe」的实例（别人目录里的实例不动），
    并且无论编译成功还是失败，最后都会把代理重新拉起来，避免出现「编到一半挂掉、
    代理被停了却没启动」的半死状态。

    用法（本机执行策略是 Restricted，所以要绕过一下）:
        powershell -ExecutionPolicy Bypass -File .\build.ps1
        powershell -ExecutionPolicy Bypass -File .\build.ps1 -Console
        powershell -ExecutionPolicy Bypass -File .\build.ps1 -OutDir D:\KBBridge
#>
param(
    [string]$OutDir = "$env:LOCALAPPDATA\KBBridge",
    [switch]$Console
)

$ErrorActionPreference = 'Stop'

$candidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw '找不到 .NET Framework 的 csc.exe' }

$sources = @(
    (Join-Path $PSScriptRoot 'KBBridge.cs'),
    (Join-Path $PSScriptRoot 'KBBridgeSettings.cs'),
    (Join-Path $PSScriptRoot 'VolumeBridge.cs'),
    (Join-Path $PSScriptRoot 'ClipboardBridge.cs')
)
foreach ($s in $sources) {
    if (-not (Test-Path $s)) { throw "找不到源文件: $s" }
}
$manifest = Join-Path $PSScriptRoot 'app.manifest'
$useManifest = Test-Path $manifest

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---- 结束「正要被覆盖」的实例（只动本目录里的那一份）----
$targetAgent    = Join-Path $OutDir 'KBBridge.exe'
$targetSettings = Join-Path $OutDir 'KBBridgeSettings.exe'
$needRestart = $false

foreach ($p in @(Get-Process KBBridge -ErrorAction SilentlyContinue)) {
    $path = $null
    try { $path = $p.Path } catch { }
    if ($path -and ($path -ieq $targetAgent)) {
        $needRestart = $true
        try { $p.Kill() } catch { }
    }
}
foreach ($p in @(Get-Process KBBridgeSettings -ErrorAction SilentlyContinue)) {
    $path = $null
    try { $path = $p.Path } catch { }
    if ($path -and ($path -ieq $targetSettings)) {
        try {
            $p.Kill()
            Write-Host '已关闭正在运行的设置窗口（它占着 KBBridgeSettings.exe，不关就没法覆盖）' -ForegroundColor Yellow
        } catch { }
    }
}
if ($needRestart) {
    Write-Host '已停止正在运行的 KBBridge（就是即将被覆盖的那个），编完会自动拉起' -ForegroundColor Yellow
    Start-Sleep -Milliseconds 500
}

$targets = @()
if ($Console) {
    $targets += [pscustomobject]@{ Target = 'exe';    Name = 'KBBridge-console.exe'; Main = 'KBBridge.Program';     Manifest = $false }
} else {
    $targets += [pscustomobject]@{ Target = 'winexe'; Name = 'KBBridge.exe';         Main = 'KBBridge.Program';     Manifest = $true }
}
$targets += [pscustomobject]@{ Target = 'winexe'; Name = 'KBBridgeSettings.exe'; Main = 'KBBridge.SettingsApp'; Manifest = $true }

try {
    foreach ($t in $targets) {
        $out = Join-Path $OutDir $t.Name
        # 注意: 不要用 $args，那是 PowerShell 的自动变量
        # /codepage:65001 是必须的：源码是 UTF-8 且无 BOM，不加的话中文会按 GBK 解析
        $cscArgs = @(
            '/nologo'
            "/target:$($t.Target)"
            "/main:$($t.Main)"
            '/optimize+'
            '/platform:anycpu'
            '/codepage:65001'
            "/out:$out"
        )
        if ($t.Manifest -and $useManifest) { $cscArgs += "/win32manifest:$manifest" }
        $cscArgs += @(
            '/r:System.dll'
            '/r:System.Core.dll'
            '/r:System.Drawing.dll'
            '/r:System.Windows.Forms.dll'
        )
        $cscArgs += $sources

        Write-Host "编译 $($t.Name) ..." -ForegroundColor Cyan
        & $csc @cscArgs
        if ($LASTEXITCODE -ne 0) { throw "编译失败（$($t.Name)），退出码 $LASTEXITCODE" }
        Write-Host "  OK -> $out" -ForegroundColor Green
    }
}
finally {
    # 不管编译成功还是失败，代理都要回到运行状态，别留个半死状态
    if ($needRestart -and -not $Console) {
        Start-Sleep -Milliseconds 300
        Start-Process $targetAgent
        Write-Host '已重新启动 KBBridge' -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '下一步: powershell -ExecutionPolicy Bypass -File .\install.ps1' -ForegroundColor Yellow
