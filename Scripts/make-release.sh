#!/usr/bin/env bash
# 打发行包：通用二进制（arm64 + x86_64）→ 组装 .app → ad-hoc 签名 → zip。
#
# 和 build-direct.sh 的区别（很重要）：
#   build-direct.sh 是「给自己用」的构建：产物落在 build/，优先用本地固定证书签名，
#   目的是让辅助功能授权跨重编译保持有效。
#   make-release.sh 是「发给别人」的构建：产物落在 build/release/，**强制 ad-hoc 签名**
#   （别人的机器上没有我们的自签名证书，用证书签反而更说不清），
#   并且编译两份架构再用 lipo 合成通用二进制——带 Touch Bar 的 MacBook Pro
#   里 Intel 机型占大头，只出 arm64 等于把它们挡在门外。
#
# 用法：
#   bash Scripts/make-release.sh              # 打当前版本
#   bash Scripts/make-release.sh --arm64-only # 只出 arm64（排障用，不要拿来发版）
#
# 产物：dist/WorkBar-<版本>-macos-universal.zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CC="/Library/Developer/CommandLineTools/usr/bin/swiftc"
APP_NAME="WorkBar"
DIST_DIR="$ROOT/dist"
STAGE="$ROOT/build/release"
APP_DIR="$STAGE/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
FW_DIR="$CONTENTS/Frameworks"
RES_DIR="$CONTENTS/Resources"

ARCHES=(arm64 x86_64)
if [[ "${1:-}" == "--arm64-only" ]]; then
  ARCHES=(arm64)
fi

# 与 build-direct.sh 保持一致的 SDK 选择逻辑（修补版优先，否则系统 SDK）
if [[ -d "$HOME/sdk-fixed/MacOSX.sdk" ]]; then
  SDK="$HOME/sdk-fixed/MacOSX.sdk"
else
  SDK="$(xcrun --show-sdk-path)"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Scripts/Info.plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Scripts/Info.plist")"
OUT="$DIST_DIR/$APP_NAME-$VERSION-macos-universal.zip"

FRAMEWORKS=(-framework AppKit -framework Speech -framework AVFoundation -framework ApplicationServices -framework ServiceManagement)

echo "[release] 版本 $VERSION · 最低系统 macOS $MIN_OS · 架构 ${ARCHES[*]}"
echo "[release] SDK = $SDK"

rm -rf "$STAGE"
mkdir -p "$MACOS_DIR" "$FW_DIR" "$RES_DIR" "$DIST_DIR"

for arch in "${ARCHES[@]}"; do
  echo "[release] 编译 $arch ..."
  # 每个架构独立目录：.swiftmodule 必须叫 TouchBarBuddy.swiftmodule 才能被 import 到，
  # 两个架构不能共用一个目录，否则后编的会覆盖前一个的模块文件。
  ADIR="$STAGE/$arch"
  mkdir -p "$ADIR"

  "$CC" -sdk "$SDK" -O -swift-version 5 -target "$arch-apple-macos$MIN_OS" \
    -emit-library -emit-module \
    -module-name TouchBarBuddy \
    -Xlinker -install_name -Xlinker @rpath/libTouchBarBuddy.dylib \
    -emit-module-path "$ADIR/TouchBarBuddy.swiftmodule" \
    -o "$ADIR/libTouchBarBuddy.dylib" \
    $(find Sources/TouchBarBuddy -name '*.swift') \
    "${FRAMEWORKS[@]}"

  "$CC" -sdk "$SDK" -O -swift-version 5 -target "$arch-apple-macos$MIN_OS" \
    -I "$ADIR" -L "$ADIR" -lTouchBarBuddy \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$ADIR/WorkBar" \
    Sources/TouchBarBuddyApp/main.swift \
    "${FRAMEWORKS[@]}"
done

echo "[release] 合成通用二进制 ..."
if [[ ${#ARCHES[@]} -gt 1 ]]; then
  lipo -create -output "$MACOS_DIR/$APP_NAME" "$STAGE"/arm64/WorkBar "$STAGE"/x86_64/WorkBar
  lipo -create -output "$FW_DIR/libTouchBarBuddy.dylib" \
    "$STAGE"/arm64/libTouchBarBuddy.dylib "$STAGE"/x86_64/libTouchBarBuddy.dylib
else
  cp "$STAGE/${ARCHES[0]}/WorkBar" "$MACOS_DIR/$APP_NAME"
  cp "$STAGE/${ARCHES[0]}/libTouchBarBuddy.dylib" "$FW_DIR/libTouchBarBuddy.dylib"
fi
chmod +x "$MACOS_DIR/$APP_NAME"

echo "[release] 组装资源 ..."
cp "$ROOT/Scripts/Info.plist" "$CONTENTS/Info.plist"
[[ -f "$ROOT/Scripts/TouchBarBuddy.icns" ]] && cp "$ROOT/Scripts/TouchBarBuddy.icns" "$RES_DIR/TouchBarBuddy.icns"
[[ -d "$ROOT/Scripts/Resources" ]] && cp -R "$ROOT/Scripts/Resources/." "$RES_DIR/"

# 发行包一律 ad-hoc 签名：别人的机器上没有我们的自签名证书，用证书签反而更说不清。
echo "[release] ad-hoc 签名 ..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR" 2>&1 | tail -2

echo "[release] 打包 zip ..."
rm -f "$OUT"
# ditto 而不是 zip：保留符号链接、扩展属性与可执行位，解压后 .app 结构才完整
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$OUT"

SIZE="$(du -h "$OUT" | awk '{print $1}')"
SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
echo ""
echo "[release] 完成：$OUT ($SIZE)"
echo "[release] sha256: $SHA"
echo "[release] 架构：$(lipo -archs "$MACOS_DIR/$APP_NAME")"
