#!/usr/bin/env bash
# 卸载 macOS 侧代理的 launchd 服务（保留 ~/.kbbridge 里的 token 和日志）
set -euo pipefail

LABEL=com.kbbridge.agent
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
    || launchctl unload "$PLIST" 2>/dev/null \
    || true

rm -f "$PLIST"

echo "已停止并移除 launchd 服务。"
echo "配置与日志仍在 ~/.kbbridge，要彻底清掉就执行: rm -rf ~/.kbbridge"
