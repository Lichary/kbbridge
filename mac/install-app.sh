#!/usr/bin/env bash
# ---------------------------------------------------------------------
# 构建 KBBridge.app 并安装到 /Applications，然后启动它。
# 一般不用直接跑它 —— 双击同目录的「安装 KBBridge.command」即可。
# ---------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="KBBridge"
DIR="$HOME/.kbbridge"
LABEL_OLD="com.kbbridge.agent"

mkdir -p "$DIR/bin" "$DIR/logs"

echo "== 0/5 准备代码签名证书（让辅助功能授权不因重编译而失效）=="
# 用户信任域不需要密码，这一步会立即返回（不加 -d 是刻意的）。
# 没有这张证书时退回 ad-hoc：open 照样成功、--check 也可能通过，
# 但下次重编译会静默掉授权，症状很隐蔽。
bash ./make-cert.sh

echo
echo "== 1/5 构建 App =="
bash ./make-app.sh "$APP_NAME.app"

echo
echo "== 2/5 准备 Token =="
if [ ! -s "$DIR/token" ]; then
    TOKEN="$(openssl rand -hex 16 2>/dev/null || true)"
    if [ -z "$TOKEN" ]; then
        TOKEN="$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 32)" || true
    fi
    printf '%s' "$TOKEN" > "$DIR/token"
    chmod 600 "$DIR/token"
    echo "  已生成新 Token"
else
    TOKEN="$(cat "$DIR/token")"
    echo "  沿用已有 Token"
fi
echo
echo "  ==========================================================="
echo "   Token = $TOKEN"
echo "   把它填到 Windows 侧 %LOCALAPPDATA%\\KBBridge\\kbbridge.ini 的 Token= 后面"
echo "  ==========================================================="

echo
echo "== 3/5 迁移旧的命令行常驻服务（如果有）=="
launchctl bootout "gui/$(id -u)/$LABEL_OLD" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL_OLD.plist"
echo "  旧的 launchd 服务已清理（app 模式不再需要它）"

echo
echo "== 4/5 安装 App =="
if [ -w /Applications ]; then
    DEST="/Applications/$APP_NAME.app"
else
    mkdir -p "$HOME/Applications"
    DEST="$HOME/Applications/$APP_NAME.app"
    echo "  /Applications 不可写，改装到 ~/Applications"
fi
rm -rf "$DEST"
cp -R "$APP_NAME.app" "$DEST"
echo "  已安装: $DEST"

# 顺手放一份命令行副本，方便跑 --check / --volume-test 这些诊断
cp "$APP_NAME.app/Contents/MacOS/$APP_NAME" "$DIR/bin/kbbridge"
chmod +x "$DIR/bin/kbbridge"

echo
echo "== 5/5 启动 =="
open "$DEST"
echo "  已启动。菜单栏右上角应该出现一个键盘图标。"

cat <<'EOT'

-----------------------------------------------------------
第一次使用还需要授权（必须做，否则按键注入会被系统丢弃）：

  1. 点菜单栏的键盘图标
  2. 点「辅助功能：未授权 ✗ —— 点这里授权」
  3. 在「系统设置 → 隐私与安全性 → 辅助功能」里把 KBBridge 打开（开关变蓝）
  4. 退出 KBBridge（菜单里「退出 KBBridge」）再重新打开一次

重新打开后，菜单里应该显示「辅助功能：已授权 ✓」。

诊断命令（可选）：
  ~/.kbbridge/bin/kbbridge --check         查看授权状态
  ~/.kbbridge/bin/kbbridge --volume-test   测旋钮音量通道
-----------------------------------------------------------
EOT
