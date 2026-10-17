#!/usr/bin/env bash
# 编译 macOS 侧代理。需要 Xcode Command Line Tools（自带 swiftc）。
#   xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-kbbridge}"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "找不到 swiftc。请先安装 Xcode Command Line Tools："
    echo "    xcode-select --install"
    exit 1
fi

# 两个要点：
# 1) -target 必须显式指定：这套 CLT 的 swiftc 默认 target 是 arm64-apple-macosx28.0，
#    会把二进制的最低系统版本写成 28.0；一旦高于实际系统，LaunchServices 会拒绝启动
#    （-10825 kLSIncompatibleSystemVersionErr），「辅助功能」里也会加不进去。
#    实测 MACOSX_DEPLOYMENT_TARGET 对 swiftc 无效。
# 2) -swift-version 5 也是必要的：Swift 6 编译器在 Swift 6 语言模式下会把本文件的
#    全局可变状态（mods / injected）判为并发不安全而直接报错。
ARCH="$(uname -m)"
MINOS="11.0"

echo "编译 $OUT （target ${ARCH}-apple-macosx${MINOS}）..."
swiftc -swift-version 5 -target "${ARCH}-apple-macosx${MINOS}" -O -o "$OUT" main.swift

# 自检：二进制要求的最低系统版本不能高于本机，否则 LaunchServices 会拒绝启动（-10825），
# 而且「辅助功能」里也会加不进这个 app。make-app.sh 里有同样的检查，这里补上，
# 避免单独跑 build.sh 时 -target 被弄坏却不报警。
if command -v vtool >/dev/null 2>&1; then
    MINOS_ACTUAL="$(vtool -show-build "$OUT" 2>/dev/null | awk '/minos/{print $2; exit}')"
    HOST_VER="$(sw_vers -productVersion)"
    echo "二进制 minos = ${MINOS_ACTUAL:-未知}    本机系统 = ${HOST_VER}"
    if [ -n "$MINOS_ACTUAL" ]; then
        LARGEST="$(printf '%s\n%s\n' "$HOST_VER" "$MINOS_ACTUAL" | sort -V | tail -1)"
        if [ "$LARGEST" != "$HOST_VER" ]; then
            echo "⚠️  二进制要求 macOS ${MINOS_ACTUAL}，但本机是 ${HOST_VER}"
            echo "    LaunchServices 会拒绝启动（-10825）。请检查上面的 -target 是否生效。"
            exit 1
        fi
    fi
fi

echo "OK -> $(pwd)/$OUT"
