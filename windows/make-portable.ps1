<#
    make-portable.ps1 — 打一个「重装系统后照做就能恢复」的便携包

    产物结构（默认写到仓库根目录的 kbbridge-portable\）：

        KBBridge.exe            常驻代理（双击即用，零依赖）
        KBBridgeSettings.exe    设置窗口
        kbbridge.ini            配置，放在 exe 旁边 = 便携模式
                                （代理优先读 exe 同目录的 ini，所以重装后不用重配）
        重装速查.txt             五步走完的恢复说明
        src\windows\...         源码 + 编译/安装脚本（要重编译时用）
        src\mac\...             macOS 侧源码 + 脚本
        src\README.md           完整文档
        src\PROTOCOL.md         协议说明

    用法:
        powershell -ExecutionPolicy Bypass -File .\make-portable.ps1
        powershell -ExecutionPolicy Bypass -File .\make-portable.ps1 -OutDir D:\Backup\KBBridge
        powershell -ExecutionPolicy Bypass -File .\make-portable.ps1 -NoToken   # 生成不含 token 的版本
#>
param(
    [string]$OutDir,
    [switch]$NoToken
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'kbbridge-portable' }

Write-Host "便携包输出目录: $OutDir" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host ''
Write-Host '--- 1/4 编译两个 exe 到便携包根目录 ---' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'build.ps1') -OutDir $OutDir

Write-Host ''
Write-Host '--- 2/4 复制源码（方便以后重编译）---' -ForegroundColor Cyan
$srcDst = Join-Path $OutDir 'src'
if (Test-Path $srcDst) { Remove-Item $srcDst -Recurse -Force }
New-Item -ItemType Directory -Force -Path $srcDst | Out-Null
foreach ($d in @('windows', 'mac', 'tools')) {
    $from = Join-Path $repoRoot $d
    if (Test-Path $from) { Copy-Item $from -Destination $srcDst -Recurse -Force }
}
foreach ($f in @('README.md', 'PROTOCOL.md')) {
    $from = Join-Path $repoRoot $f
    if (Test-Path $from) { Copy-Item $from -Destination $srcDst -Force }
}
Get-ChildItem $srcDst -Recurse -File -Include *.exe, *.pdb, *.log, *.pyc -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem $srcDst -Recurse -Directory -Filter __pycache__ -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '--- 3/4 生成便携配置 ---' -ForegroundColor Cyan
$iniDst = Join-Path $OutDir 'kbbridge.ini'
$existing = @(
    (Join-Path "$env:LOCALAPPDATA\KBBridge" 'kbbridge.ini')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($existing) {
    $lines = Get-Content $existing -Encoding UTF8
    if ($NoToken) {
        $lines = $lines | ForEach-Object {
            if ($_ -match '^\s*Token\s*=') { 'Token=<把 Mac 上 ~/.kbbridge/token 的内容粘这里>' } else { $_ }
        }
    }
    Set-Content -Path $iniDst -Value $lines -Encoding UTF8
    Write-Host "已复制当前配置: $existing -> $iniDst" -ForegroundColor Green
} else {
    Set-Content -Path $iniDst -Encoding UTF8 -Value @(
        '# KBBridge 配置（Windows 侧）',
        'MacHost=<Mac 的 IP 或主机名>',
        'Port=38471',
        'Token=<Mac 上 ~/.kbbridge/token 的内容>',
        'Beep=true',
        'Tray=true',
        'Log=true',
        'SyncHeldKeys=true',
        'VerboseKeys=false',
        'SwitchToMacHotkey=Ctrl+Alt+M',
        'RescueHotkey=Ctrl+Alt+Shift+W'
    )
    Write-Host "没找到现有配置，已生成模板: $iniDst" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '--- 4/4 写恢复说明 ---' -ForegroundColor Cyan
$quick = @'
KBBridge 便携包 —— 重装系统后的恢复步骤
==========================================

【Windows 侧】大概 1 分钟
 1. 把整个文件夹放到一个固定位置，比如 D:\Tools\KBBridge
    （放进网盘同步目录也可以，但注意 kbbridge.ini 里有共享密钥）
 2. 双击 KBBridge.exe —— 托盘出现彩色圆点就说明开始工作了
    配置就在旁边的 kbbridge.ini 里，Mac 地址和 Token 都还在，不用重配
 3. 想开机自启：双击 KBBridgeSettings.exe → 勾上「开机自启」→ 保存并重启服务

【macOS 侧】换机或重装后大概 5 分钟
 1. 装 Xcode Command Line Tools（如果没有）:  xcode-select --install
 2. 把 src/mac 拷到 Mac 上，然后:
        cd mac && chmod +x *.sh
        ./install.sh --token <本目录 kbbridge.ini 里 Token= 后面那串>
 3. 授予「辅助功能」权限（必须做，否则按键会被系统静默丢弃）:
        ~/.kbbridge/bin/kbbridge --port 38471      # 手动跑一次让它弹授权框，然后 Ctrl+C
        # 没弹窗就去 系统设置 → 隐私与安全性 → 辅助功能 添加 ~/.kbbridge/bin/kbbridge
        launchctl kickstart -k gui/$(id -u)/com.kbbridge.agent
        ~/.kbbridge/bin/kbbridge --check           # 必须打印「已授权」
 4. 确认 Mac 的地址没变:  ipconfig getifaddr en0
    变了就双击 KBBridgeSettings.exe 改一下 Mac 地址

【日常使用】
  Ctrl + Alt + M         键盘交给 Mac
  Ctrl + Alt + W         交还 Windows
  Ctrl + Alt + Shift + W 强制救援回 Windows（纯本地，不走网络，Mac 关机也有效）
  托盘图标：蓝 = 键盘在 Windows，橙 = 键盘在 Mac；右键有「设置…」「切回 Windows」「退出」

【出问题先看哪里】
  1. 双击 KBBridgeSettings.exe 点「测试连接」——它会直接告诉你是端口不通、Token 不对、还是没授权
  2. Windows 日志: %LOCALAPPDATA%\KBBridge\kbbridge.log
  3. Mac 日志:     ~/.kbbridge/logs/agent.log
  4. 完整文档:     src\README.md 的「故障排查」一节

【安全提醒】
  kbbridge.ini 里的 Token 相当于一把钥匙（协议本身不加密）。
  如果要把它放进网盘/共享目录，建议改用不含 Token 的版本：
      powershell -ExecutionPolicy Bypass -File .\src\windows\make-portable.ps1 -NoToken

【要改代码重新编译】
  Windows:  powershell -ExecutionPolicy Bypass -File .\src\windows\build.ps1 -OutDir .
  macOS:    cd src/mac && ./build.sh   （注意：重编译后需要在系统设置里重新授予辅助功能权限）
'@
Set-Content -Path (Join-Path $OutDir '重装速查.txt') -Value $quick -Encoding UTF8

Write-Host ''
Write-Host '完成。便携包内容：' -ForegroundColor Green
Get-ChildItem $OutDir | ForEach-Object { '  ' + $_.Name }
Write-Host ''
if (-not $NoToken) {
    Write-Host '提醒: kbbridge.ini 里含有共享 Token（相当于钥匙），放到网盘前请自行取舍。' -ForegroundColor Yellow
}
