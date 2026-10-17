<#
    install.ps1 — 安装 Windows 侧代理

      1) 编译 KBBridge.exe 到 %LOCALAPPDATA%\KBBridge
      2) 生成/写入 kbbridge.ini（含 Mac 地址、端口、共享 token）
      3) 注册开机自启（「启动」文件夹快捷方式，不需要管理员）
      4) 立刻启动它

    用法:
        powershell -ExecutionPolicy Bypass -File .\install.ps1 -MacHost 192.168.1.50
        powershell -ExecutionPolicy Bypass -File .\install.ps1 -MacHost mac.local -Token <32位hex>
        （不带 -MacHost 会交互式问你）

    注意：这台机器的执行策略是 Restricted，所以必须带 -ExecutionPolicy Bypass
#>
param(
    [string]$MacHost,
    [int]$Port = 38471,
    [string]$Token,
    [switch]$NoStartup,
    [switch]$NoRun
)

$ErrorActionPreference = 'Stop'

if (-not $MacHost) {
    $MacHost = Read-Host '请输入 Mac 的 IP 或主机名（例如 192.168.1.50 或 MacBook.local）'
}
if (-not $MacHost) { throw '必须指定 Mac 的地址' }

$dir = Join-Path $env:LOCALAPPDATA 'KBBridge'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Write-Host ''
Write-Host '--- 1/4 编译 ---' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'build.ps1') -OutDir $dir
$exe = Join-Path $dir 'KBBridge.exe'
if (-not (Test-Path $exe)) { throw "编译产物不存在: $exe" }

Write-Host ''
Write-Host '--- 2/4 写配置 ---' -ForegroundColor Cyan
if (-not $Token) {
    $bytes = New-Object byte[] 16
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($bytes)
    $Token = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    Write-Host '已生成新的 token' -ForegroundColor Yellow
}

$iniPath = Join-Path $dir 'kbbridge.ini'
$ini = @"
# KBBridge Windows 侧配置
# 改完这个文件后需要重启 KBBridge.exe（托盘图标右键 → 退出，再双击 exe）
#
# Mac 的 IP 或主机名
MacHost=$MacHost
# 和 Mac 侧 ~/.kbbridge/token 必须完全一致
Port=$Port
Token=$Token
# 切换时是否用蜂鸣提示
Beep=true
# 是否显示托盘图标（右键菜单里有“切回 Windows”，Mac 挂了时很有用）
Tray=true
# 是否写日志到 %LOCALAPPDATA%\KBBridge\kbbridge.log
Log=true
# 切到 Mac 时，把当前还按住的键（比如你正按着 Ctrl）补发给 Mac
SyncHeldKeys=true
# 键盘交给 Mac（Windows 本地识别）
SwitchToMacHotkey=Ctrl+Alt+M
# 强制救援回 Windows（Windows 本地识别，不走网络，Mac 睡眠/断网时用）
RescueHotkey=Ctrl+Alt+Shift+W
"@
Set-Content -Path $iniPath -Value $ini -Encoding UTF8
Write-Host "已写入 $iniPath" -ForegroundColor Green

Write-Host ''
Write-Host '--- 3/4 注册开机自启 ---' -ForegroundColor Cyan
if ($NoStartup) {
    Write-Host '按要求跳过（-NoStartup）' -ForegroundColor DarkGray
} else {
    $startup = [Environment]::GetFolderPath('Startup')
    $lnkPath = Join-Path $startup 'KBBridge.lnk'
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnkPath)
        $sc.TargetPath = $exe
        $sc.WorkingDirectory = $dir
        $sc.Description = 'KBBridge 键盘桥'
        $sc.Save()
        Write-Host "已创建启动快捷方式: $lnkPath" -ForegroundColor Green
    } catch {
        Copy-Item $exe (Join-Path $startup 'KBBridge.exe') -Force
        Write-Host "已复制到启动文件夹: $startup\KBBridge.exe" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '--- 4/4 启动 ---' -ForegroundColor Cyan
if ($NoRun) {
    Write-Host '按要求跳过（-NoRun），你可以双击那个 exe 手动启动' -ForegroundColor DarkGray
} else {
    Get-Process KBBridge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    Start-Process -FilePath $exe
    Write-Host 'KBBridge 已启动（看托盘里有没有出现彩色圆点）' -ForegroundColor Green
}

Write-Host ''
Write-Host '===========================================================' -ForegroundColor Yellow
Write-Host ' 把下面这一行抄到 Mac 上，让两边 token 一致：' -ForegroundColor Yellow
Write-Host ''
Write-Host "   ./install.sh --token $Token" -ForegroundColor White
Write-Host ''
Write-Host ' （如果 Mac 侧已经装好了，就编辑 ~/.kbbridge/token 改成这个值,' -ForegroundColor Yellow
Write-Host '   然后 launchctl kickstart -k gui/$(id -u)/com.kbbridge.agent）' -ForegroundColor Yellow
Write-Host '===========================================================' -ForegroundColor Yellow
Write-Host ''
Write-Host '自检（不装钩子，只测协议，需要 Mac 侧已就绪）：' -ForegroundColor Cyan
Write-Host "   & '$dir\KBBridge-console.exe' --selftest --host $MacHost --port $Port --token $Token" -ForegroundColor DarkGray
Write-Host ''
