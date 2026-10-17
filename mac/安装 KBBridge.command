#!/usr/bin/env bash
# 双击我即可：构建 KBBridge.app、装到「应用程序」、并启动它。
cd "$(dirname "$0")"
bash ./install-app.sh
echo
echo "按回车键关闭这个窗口 ..."
read -r _ || true
