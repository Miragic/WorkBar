#!/usr/bin/env bash
# 直接编译版构建（不使用 SwiftPM）
#
# 为什么需要这个脚本：
#   本机 Command Line Tools 的两处组件版本不一致，导致 `swift build` 无法工作
#   （Swift 编译器 6.0.3.1.10 vs SDK / libPackageDescription 6.0.3.1.5，
#    manifest 链接时报 Undefined symbols for architecture arm64）。
#   `swiftc` 本身可用，因此改为直接编译：先编库模块，再编可执行文件，最后组装 .app。
#
# 用法：bash Scripts/build-direct.sh
# 产物：build/WorkBar.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CC="/Library/Developer/CommandLineTools/usr/bin/swiftc"

# SDK 选择：优先用修补版（版本标记与编译器对齐），否则回退系统 SDK。
PATCHED_SDK="$HOME/sdk-fixed/MacOSX.sdk"
if [[ -d "$PATCHED_SDK" ]]; then
  SDK="$PATCHED_SDK"
  echo "[build-direct] SDK = 修补版 $SDK"
else
  SDK="$(xcrun --show-sdk-path)"
  echo "[build-direct] SDK = 系统 $SDK"
fi

APP_NAME="WorkBar"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
FW_DIR="$CONTENTS/Frameworks"
RES_DIR="$CONTENTS/Resources"

COMMON_FLAGS=(-sdk "$SDK" -O -swift-version 5)
# ServiceManagement：开机自启用 macOS 13+ 的 SMAppService（官方接口）。
# 显式列出而不依赖 Swift 的 autolink，避免换 SDK 后链接阶段才暴露缺框架。
FRAMEWORKS=(-framework AppKit -framework Speech -framework AVFoundation -framework ApplicationServices -framework ServiceManagement)

echo "[build-direct] 1/5 编译库模块 TouchBarBuddy ..."
mkdir -p "$BUILD_DIR"
"$CC" "${COMMON_FLAGS[@]}" \
  -emit-library -emit-module \
  -module-name TouchBarBuddy \
  -Xlinker -install_name -Xlinker @rpath/libTouchBarBuddy.dylib \
  -emit-module-path "$BUILD_DIR/TouchBarBuddy.swiftmodule" \
  -o "$BUILD_DIR/libTouchBarBuddy.dylib" \
  $(find Sources/TouchBarBuddy -name '*.swift') \
  "${FRAMEWORKS[@]}"

echo "[build-direct] 2/5 编译可执行文件 ..."
"$CC" "${COMMON_FLAGS[@]}" \
  -I "$BUILD_DIR" -L "$BUILD_DIR" -lTouchBarBuddy \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$BUILD_DIR/TouchBarBuddyApp" \
  Sources/TouchBarBuddyApp/main.swift \
  "${FRAMEWORKS[@]}"

echo "[build-direct] 3/5 组装 $APP_NAME.app ..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FW_DIR" "$RES_DIR"
cp "$BUILD_DIR/TouchBarBuddyApp" "$MACOS_DIR/$APP_NAME"
cp "$BUILD_DIR/libTouchBarBuddy.dylib" "$FW_DIR/"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "[build-direct] 4/5 写入 Info.plist 与图标 ..."
cp "$ROOT/Scripts/Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$ROOT/Scripts/TouchBarBuddy.icns" ]]; then
  cp "$ROOT/Scripts/TouchBarBuddy.icns" "$RES_DIR/TouchBarBuddy.icns"
else
  echo "[build-direct]   提示：未找到 Scripts/TouchBarBuddy.icns，app 将使用系统默认图标"
fi
# 菜单栏模板图（22pt @1x/@2x）
if [[ -d "$ROOT/Scripts/Resources" ]]; then
  cp -R "$ROOT/Scripts/Resources/." "$RES_DIR/"
fi

# 签名策略：优先用固定的本地自签名证书，其次退回 ad-hoc。
#
# 为什么必须优先用证书：
#   ad-hoc 签名没有稳定身份，TCC（辅助功能授权）只能按 cdhash 记录授权条目。
#   cdhash 随二进制内容变化，于是「每改一行代码就得重新授权一次」。
#   用固定证书签名后，designated requirement 变成
#       identifier "com.miragic.touchbarbuddy" and certificate leaf = H"<sha1>"
#   与内容无关，一次授权长期有效（同证书、同 bundle id 即可）。
#   证书由 Scripts/setup-signing-identity.sh 创建，可用 TB_SIGN_IDENTITY 覆盖。
SIGN_IDENTITY="${TB_SIGN_IDENTITY:-TouchBarBuddy Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  echo "[build-direct] 5/5 用证书签名：$SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  echo "[build-direct] 5/5 ad-hoc 签名（未找到证书 '$SIGN_IDENTITY'；"
  echo "              跑一次 Scripts/setup-signing-identity.sh 可让授权跨重编译保留）"
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "[build-direct] 完成：$APP_DIR"
