<#
    uninstall.ps1 — 停止 Windows 侧代理并移除开机自启
    默认保留配置和日志；加 -RemoveConfig 一起删掉
#>
param(
    [switch]$RemoveConfig
)

$ErrorActionPreference = 'Continue'

Get-Process KBBridge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host '已停止 KBBridge 进程'

$startup = [Environment]::GetFolderPath('Startup')
foreach ($f in @('KBBridge.lnk', 'KBBridge.exe')) {
    $p = Join-Path $startup $f
    if (Test-Path $p) {
        Remove-Item $p -Force
        Write-Host "已移除 $p"
    }
}

if ($RemoveConfig) {
    $dir = Join-Path $env:LOCALAPPDATA 'KBBridge'
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force
        Write-Host "已删除 $dir"
    }
} else {
    Write-Host "配置和日志仍保留在 $env:LOCALAPPDATA\KBBridge"
}
