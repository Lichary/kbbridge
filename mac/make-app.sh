#!/usr/bin/env bash
# ---------------------------------------------------------------------
# 把 main.swift 编译并组装成一个真正的 macOS App（菜单栏 App）
#
#   ./make-app.sh                  -> 生成 ./KBBridge.app
#   ./make-app.sh /tmp/MyApp.app   -> 指定输出位置
#
# 不用 Xcode 工程，就是手工拼 .app 目录结构 + Info.plist，最后 ad-hoc 签名。
# ---------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="KBBridge"
BUNDLE_ID="com.kbbridge.app"
APP_DIR="${1:-$APP_NAME.app}"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "找不到 swiftc。请先安装 Xcode Command Line Tools："
    echo "    xcode-select --install"
    exit 1
fi

# 关键：必须显式指定 deployment target！
# 这套 CLT 的 swiftc 默认 target 是 arm64-apple-macosx28.0，会把 LC_BUILD_VERSION
# 的 minos 写成 28.0 —— 一旦高于实际系统版本，LaunchServices 就会拒绝启动：
#     kLSIncompatibleSystemVersionErr (-10825)
# 而且会连带导致「辅助功能」里加不进这个 app（tccd 解析不到 bundle，报 -10814）。
# 注意：实测 MACOSX_DEPLOYMENT_TARGET 对 swiftc 无效，必须用 -target。
ARCH="$(uname -m)"
MINOS="11.0"

echo "1/3 编译（target ${ARCH}-apple-macosx${MINOS}）..."
TMP_BIN="$(mktemp -t kbbridge)"
swiftc -swift-version 5 -target "${ARCH}-apple-macosx${MINOS}" -O -o "$TMP_BIN" main.swift

echo "2/3 组装 $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$TMP_BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
rm -f "$TMP_BIN"

# ---- 自检：二进制要求的最低系统版本不能高于本机，否则 open 会 -10825 ----
if command -v vtool >/dev/null 2>&1; then
    MINOS_ACTUAL="$(vtool -show-build "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null | awk '/minos/{print $2; exit}')"
    HOST_VER="$(sw_vers -productVersion)"
    echo "  二进制 minos = ${MINOS_ACTUAL:-未知}    本机系统 = $HOST_VER"
    if [ -n "$MINOS_ACTUAL" ]; then
        LARGEST="$(printf '%s\n%s\n' "$HOST_VER" "$MINOS_ACTUAL" | sort -V | tail -1)"
        if [ "$LARGEST" != "$HOST_VER" ]; then
            echo "  ⚠️  二进制要求 macOS ${MINOS_ACTUAL}，但本机是 ${HOST_VER}"
            echo "     LaunchServices 会拒绝启动（-10825），并且辅助功能里也加不进去。"
            echo "     请检查上面的 -target 是否生效。"
            exit 1
        fi
    fi
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.2.0</string>
    <key>CFBundleVersion</key><string>1.2.0</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>KBBridge</string>
</dict>
</plist>
PLIST

echo "3/3 签名 ..."
if command -v codesign >/dev/null 2>&1; then
    # 优先用「自签名证书」，而不是 ad-hoc。
    # 原因：ad-hoc 签名时 TCC 用 cdhash 记录授权，重编译就掉；换成证书签名后
    # TCC 记的是 certificate leaf，重编译、改源码都不会掉授权（已实测）。
    # 证书由 make-cert.sh 创建（identity 名默认 KBBridge Local Signing）。
    SIGN_ID="${KBBRIDGE_SIGN_ID:-}"
    if [ -z "$SIGN_ID" ]; then
        SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/KBBridge/{print $2; exit}')"
    fi
    SIGN_ERR="$(mktemp -t kbbridge-sign)"

    if [ -n "$SIGN_ID" ]; then
        if codesign --force --deep --sign "$SIGN_ID" "$APP_DIR" 2>"$SIGN_ERR"; then
            echo "  已用证书签名: ${SIGN_ID}"
        else
            # 不要吞掉 codesign 的报错 —— 静默失败会让人绕远路
            echo "  !! 证书签名失败，codesign 的报错如下："
            sed 's/^/     /' "$SIGN_ERR"
            echo "  回退 ad-hoc 签名"
            codesign --force --deep --sign - "$APP_DIR" || echo "  !! ad-hoc 签名也失败了"
        fi
    else
        if codesign --force --deep --sign - "$APP_DIR" 2>"$SIGN_ERR"; then
            echo "  已 ad-hoc 签名（没找到名字带 KBBridge 的自签名证书）"
            echo "  提示: ad-hoc 下重编译会让辅助功能授权失效，跑 ./make-cert.sh 可避免。"
        else
            echo "  !! ad-hoc 签名失败："
            sed 's/^/     /' "$SIGN_ERR"
        fi
    fi
    rm -f "$SIGN_ERR"
else
    echo "  没有 codesign，跳过"
fi

echo
echo "完成 -> $(pwd)/$APP_DIR"
echo "双击它即可运行；第一次运行后到「系统设置 → 隐私与安全性 → 辅助功能」里把它打开。"
