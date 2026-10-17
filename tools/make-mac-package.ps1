<#
    make-mac-package.ps1 — 把 mac/ 打包成 macOS 上「双击就能解压」的 tar.gz

    为什么要自己拼 tar：
      · Windows 自带的 tar.exe 是精简版，不支持 --mode
      · zip 不保留 Unix 可执行位 —— 解压出来的 .command 双击会失败
    所以这里手工写 ustar 头，把每个文件的 mode 明确写成 0755。

    用法:
        powershell -ExecutionPolicy Bypass -File .\tools\make-mac-package.ps1
#>
param(
    [string]$OutFile = ""
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$macDir   = Join-Path $repoRoot 'mac'
if (-not $OutFile) { $OutFile = Join-Path (Split-Path -Parent $repoRoot) 'kbbridge-mac.tar.gz' }

$names = @(
    'main.swift'
    'make-cert.sh'
    'make-app.sh'
    'install-app.sh'
    'install.sh'
    'uninstall.sh'
    'build.sh'
    '安装 KBBridge.command'
    'README.md'
    'PROTOCOL.md'
)

$files = @()
foreach ($n in $names) {
    $p = Join-Path $macDir $n
    if (-not (Test-Path $p) -and ($n -eq 'README.md' -or $n -eq 'PROTOCOL.md')) {
        $p = Join-Path $repoRoot $n
    }
    if (-not (Test-Path $p)) { throw "找不到文件: $n" }
    $files += [pscustomobject]@{ Path = $p; Name = "KBBridge-mac/$n" }
}

function New-TarHeader([string]$name, [int]$mode, [long]$size) {
    $hdr = New-Object byte[] 512
    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($name)
    if ($nameBytes.Length -gt 100) { throw "文件名超过 100 字节: $name" }
    [Array]::Copy($nameBytes, 0, $hdr, 0, $nameBytes.Length)

    $modeStr = [Convert]::ToString($mode, 8).PadLeft(7, '0') + "`0"
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes($modeStr), 0, $hdr, 100, 8)
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes("0000000`0"), 0, $hdr, 108, 8)
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes("0000000`0"), 0, $hdr, 116, 8)

    $sizeStr = [Convert]::ToString($size, 8).PadLeft(11, '0') + "`0"
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes($sizeStr), 0, $hdr, 124, 12)

    $mtime = [long]((Get-Date) - (Get-Date '1970-01-01 00:00:00')).TotalSeconds
    $mtStr = [Convert]::ToString($mtime, 8).PadLeft(11, '0') + "`0"
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes($mtStr), 0, $hdr, 136, 12)

    # 校验和字段先填 8 个空格
    for ($i = 148; $i -lt 156; $i++) { $hdr[$i] = 32 }
    $hdr[156] = [byte][char]'0'        # typeflag: 普通文件
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('ustar'), 0, $hdr, 257, 5)
    $hdr[262] = 0
    $hdr[263] = [byte][char]'0'
    $hdr[264] = [byte][char]'0'
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('kbbridge'), 0, $hdr, 265, 8)
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes('staff'), 0, $hdr, 297, 5)

    $sum = 0
    foreach ($b in $hdr) { $sum += $b }
    $chk = [Convert]::ToString($sum, 8).PadLeft(6, '0') + "`0 "
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes($chk), 0, $hdr, 148, 8)
    return $hdr
}

$ms = New-Object System.IO.MemoryStream
foreach ($f in $files) {
    $data = [System.IO.File]::ReadAllBytes($f.Path)
    $hdr = New-TarHeader -name $f.Name -mode 0x1ED -size $data.Length   # 0x1ED = 0755
    $ms.Write($hdr, 0, 512)
    $ms.Write($data, 0, $data.Length)
    $pad = (512 - ($data.Length % 512)) % 512
    if ($pad -gt 0) { $ms.Write((New-Object byte[] $pad), 0, $pad) }
}
$ms.Write((New-Object byte[] 1024), 0, 1024)   # 两个全零块收尾

$raw = $ms.ToArray()
Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
$fs = [System.IO.File]::Create($OutFile)
$gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionLevel]::Optimal)
$gz.Write($raw, 0, $raw.Length)
$gz.Close()
$fs.Close()

"已生成: $OutFile  ($([math]::Round((Get-Item $OutFile).Length/1KB,1)) KB, $($files.Count) 个文件)"
""
"--- 校验包内的权限位（mode 应为 100755）---"
$off = 0
while ($off + 512 -le $raw.Length) {
    $nm = [System.Text.Encoding]::UTF8.GetString($raw, $off, 100).Trim([char]0)
    if ([string]::IsNullOrWhiteSpace($nm)) { break }
    $md = [System.Text.Encoding]::ASCII.GetString($raw, $off + 100, 8).Trim([char]0, ' ')
    $sz = [Convert]::ToInt64([System.Text.Encoding]::ASCII.GetString($raw, $off + 124, 12).Trim([char]0, ' '), 8)
    $flag = if ($md -eq '0000755') { 'OK' } else { '!! 权限不对' }
    '  {0,-40} mode={1}  {2}' -f $nm, $md, $flag
    $off += 512 + [int]([math]::Ceiling($sz / 512.0) * 512)
}
