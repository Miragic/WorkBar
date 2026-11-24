#!/bin/bash
#
# 创建并导入本地自签名代码签名证书 "TouchBarBuddy Dev"。
#
# 目的：让「辅助功能」授权在重编译后依然有效。
#   - ad-hoc 签名（codesign -s -）没有稳定身份，TCC 只能按 cdhash 记住授权，
#     而 cdhash = 二进制内容哈希，改一行代码就变 → 每次重新编译都要重新授权。
#   - 固定证书签名后 designated requirement 是
#         identifier "com.miragic.touchbarbuddy" and certificate leaf = H"<sha1>"
#     与内容无关 → 一次授权、长期有效。
#
# 幂等：已存在同名身份时直接退出，不重复导入。
# 卸载：security delete-identity -c "TouchBarBuddy Dev" ~/Library/Keychains/login.keychain-db
#
set -euo pipefail

IDENTITY_NAME="${TB_SIGN_IDENTITY:-TouchBarBuddy Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK_DIR="${TMPDIR:-/tmp}/tb-signing-setup"
P12_PASS="tbdev"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
  echo "[signing] 身份 '$IDENTITY_NAME' 已存在，跳过创建。"
  exit 0
fi

echo "[signing] 生成自签名证书 '$IDENTITY_NAME' ..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout key.pem -out cert.pem \
  -subj "/CN=$IDENTITY_NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# -legacy：新版本 openssl 默认用 AES-256-CBC + PBES2 封装 p12，
# macOS 的 security import 不认，必须退回旧算法。
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem \
  -out identity.p12 -passout "pass:$P12_PASS" -name "$IDENTITY_NAME" 2>/dev/null

echo "[signing] 导入登录钥匙串（-A 允许 codesign 无提示访问私钥）..."
security import identity.p12 -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -A 2>&1 | tail -2

echo "[signing] 校验 ..."
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
  echo "[signing] 完成：'$IDENTITY_NAME' 可用于签名。"
  echo "[signing] 现在运行 Scripts/build-direct.sh 会自动用它签名。"
else
  echo "[signing] 失败：导入后仍找不到可用身份。" >&2
  echo "[signing] 可能需要先解锁钥匙串：security unlock-keychain $KEYCHAIN" >&2
  exit 1
fi

# 清理私钥明文残留
rm -f "$WORK_DIR/key.pem"
