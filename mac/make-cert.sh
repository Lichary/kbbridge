#!/usr/bin/env bash
# ---------------------------------------------------------------------
# 建一个本地自签名「代码签名」证书，让 KBBridge 的辅助功能授权不再因为
# 重新编译而失效。跑一次就够，之后 make-app.sh 会自动用它签名。
#
#   ./make-cert.sh
#
# 来源：本脚本由 macOS 侧 agent 实测编写并验证（macOS 27.0 / arm64 /
#       OpenSSL 3.6.3 / bash 3.2.57），经 Windows 侧并入仓库。
#
# 背景（为什么需要这个）：
#   ad-hoc 签名（codesign --sign -）的 designated requirement 就是 cdhash，
#   例如  designated => cdhash H"ce2a3b72..."
#   而 cdhash 每次重新编译都会变，于是 TCC 里存的授权对不上新二进制，
#   辅助功能开关就掉了，得去「系统设置 → 隐私与安全性 → 辅助功能」重新勾。
#
#   换成证书签名后，DR 变成：
#     designated => identifier "com.kbbridge.app" and certificate leaf = H"..."
#   里面不含 cdhash，所以重编译后授权依然有效（已实测：cdhash 变了仍「已授权」）。
#
# 注意：证书只装到「用户」信任域（不加 sudo / 不加 -d），不动系统信任设置。
#      用户信任域**不需要密码**，命令会立即返回；只有误加 -d（写 admin 域）才会要求
#      输入登录密码 —— 所以整个设计的要点就是别加 -d。
# ---------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

CERT_CN="KBBridge Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d -t kbbridge-cert)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_CN"; then
    echo "证书「${CERT_CN}」已存在，不用重建："
    security find-identity -v -p codesigning | grep -F "$CERT_CN"
    exit 0
fi

echo "1/4 生成自签名证书 ..."
# 这里必须用「不带引号」的 heredoc，让 ${CERT_CN} 展开进去。
# 曾经写成 <<'CNF' 并在里面硬编码 CN，结果改 CERT_CN 时证书名和变量不一致，
# 会静默建出一张名字不对的证书（find-identity 里两把同名不同 hash 的证书）。
cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = v3_codesign
prompt             = no

[dn]
CN = ${CERT_CN}

[v3_codesign]
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.cnf" >/dev/null 2>&1

# 自检：证书 subject 的 CN 必须真的等于 CERT_CN
GOT_CN="$(openssl x509 -in "$WORK/cert.pem" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')"
if [ "$GOT_CN" != "$CERT_CN" ]; then
    echo "  !! 证书 CN 与预期不符：期望「${CERT_CN}」，实际「${GOT_CN}」"
    exit 1
fi
echo "    CN = ${GOT_CN} ✓"

echo "2/4 打包成 p12 ..."
# 必须用 SHA1 + 3DES：OpenSSL 3.x 默认的 AES-256-CBC/SHA-256 格式
# macOS 的 security 工具验不过，会报
#   SecKeychainItemImport: MAC verification failed during PKCS12 import
# —— 看着像密码错，其实是算法不兼容。
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" \
    -name "$CERT_CN" -passout pass:kbbridge \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

echo "3/4 导入 login keychain（只允许 codesign 使用私钥）..."
security import "$WORK/id.p12" -k "$KEYCHAIN" -P kbbridge \
    -T /usr/bin/codesign -T /usr/bin/security

echo "4/4 设为信任（仅代码签名，用户域）..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

# 最终自检：必须恰好能找到这把可用的签名身份
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_CN"; then
    echo "  !! 导入后 find-identity 里找不到「${CERT_CN}」，签名会失败"
    exit 1
fi

echo
echo "完成。可用签名身份："
security find-identity -v -p codesigning
echo
echo "现在跑 ./make-app.sh 就会自动用这个证书签名。"
