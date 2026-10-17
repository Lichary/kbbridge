#!/usr/bin/env bash
# ---------------------------------------------------------------------
# 安装 macOS 侧代理：编译 + 写 token + 注册 launchd 开机自启
# 全程不需要 sudo：程序装到 ~/.kbbridge/bin，服务注册在 ~/Library/LaunchAgents
#
# 用法:
#   ./install.sh                        # 自动生成 token
#   ./install.sh --token <32位hex>      # 用指定 token（和 Windows 侧保持一致）
#   ./install.sh --port 38471 --bind 0.0.0.0
# ---------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

PORT=38471
BIND=0.0.0.0
TOKEN=""
LABEL=com.kbbridge.agent
DIR="$HOME/.kbbridge"
BIN="$DIR/bin/kbbridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

while [ $# -gt 0 ]; do
    case "$1" in
        --port)  PORT="$2"; shift 2 ;;
        --bind)  BIND="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

if ! command -v swiftc >/dev/null 2>&1; then
    echo "找不到 swiftc。请先执行: xcode-select --install"
    exit 1
fi

mkdir -p "$DIR/bin" "$DIR/logs"

echo "编译中 ..."
# -swift-version 5：见 build.sh 里的说明
swiftc -swift-version 5 -O -o "$BIN" main.swift
chmod +x "$BIN"

# 生成 token。
# 千万别写成 `TOKEN="$(tr -dc 'a-f0-9' < /dev/urandom | head -c 32)"`：
# head 读够 32 字节就退出 → tr 收到 SIGPIPE 返回 141 → 配合脚本开头的
# set -o pipefail + set -e，整个脚本会「没有任何报错地静默退出」。
# openssl 是 macOS 自带的，没有这个坑。
generate_token() {
    local t
    t="$(openssl rand -hex 16 2>/dev/null)" || true
    if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi
    # openssl 万一不可用时的兜底（|| true 用来吞掉上面那个 SIGPIPE 状态）
    t="$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 32)" || true
    printf '%s' "$t"
    return 0
}

if [ -z "$TOKEN" ]; then
    if [ -f "$DIR/token" ]; then
        TOKEN="$(cat "$DIR/token")"
        echo "沿用已有的 token"
    else
        TOKEN="$(generate_token)"
        echo "已生成新 token"
    fi
fi
printf '%s' "$TOKEN" > "$DIR/token"
chmod 600 "$DIR/token"

echo
echo "==========================================================="
echo "  token = $TOKEN"
echo
echo "  把这一串填到 Windows 的 %LOCALAPPDATA%\\KBBridge\\kbbridge.ini 里："
echo "      Token=$TOKEN"
echo "==========================================================="
echo

# token 不写进 plist：命令行的参数在 ps 里能被别的用户看到，从文件读更安全
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>--port</string><string>$PORT</string>
        <string>--bind</string><string>$BIND</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$DIR/logs/agent.log</string>
    <key>StandardErrorPath</key><string>$DIR/logs/agent.err</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    echo "已注册 launchd 服务 (bootstrap)"
else
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load -w "$PLIST"
    echo "已注册 launchd 服务 (旧式 load)"
fi

cat <<EOT

-----------------------------------------------------------
下一步：授予「辅助功能」权限，否则按键注入会被系统静默丢弃

  1) 打开「系统设置 → 隐私与安全性 → 辅助功能」
     点 + 号添加下面这个文件（选择框里按 Cmd+Shift+G 可直接粘路径）：
         $BIN

  2) 重启服务让它生效：
         launchctl kickstart -k gui/$(id -u)/$LABEL

  3) 看日志确认：
         tail -f $DIR/logs/agent.log
     应该出现「辅助功能权限: 已授权」

  小技巧：先在终端手动跑一次，系统会直接弹出授权请求
         $BIN --port $PORT
         (Ctrl+C 结束，然后执行第 2 步)

  说明：launchd 启动的进程可能不会弹授权框，所以「手动跑一次 → 授权 → kickstart」
        是最省事的顺序。授权是按二进制路径记录的，重编译后需要重新授权。
-----------------------------------------------------------
EOT
