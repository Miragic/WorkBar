#!/usr/bin/env bash
# 构建 WorkBar.app（ad-hoc 签名的 .app bundle）。
#
# 为什么要打成 .app 再运行：
#   macOS 上申请语音识别 / 麦克风权限时，若 Info.plist 缺少对应的 usage description key，
#   系统会【直接终止进程】（不是弹窗拒绝）。因此必须以带 Info.plist 的 .app 形式运行。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="WorkBar"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
PRODUCT_BIN="$ROOT/.build/release/touchbar-buddy"
INFO_PLIST_SRC="$ROOT/Scripts/Info.plist"

echo "[build-app] 1/4 swift build -c release ..."
swift build -c release

if [[ ! -f "$PRODUCT_BIN" ]]; then
  echo "[build-app] 错误：未找到可执行产物 $PRODUCT_BIN" >&2
  exit 1
fi
if [[ ! -f "$INFO_PLIST_SRC" ]]; then
  echo "[build-app] 错误：未找到 Info.plist 模板 $INFO_PLIST_SRC" >&2
  exit 1
fi

echo "[build-app] 2/4 组装 $APP_NAME.app ..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$PRODUCT_BIN" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "[build-app] 3/4 写入 Info.plist ..."
cp "$INFO_PLIST_SRC" "$CONTENTS/Info.plist"

echo "[build-app] 4/4 ad-hoc 签名 ..."
codesign --force --deep --sign - "$APP_DIR"

echo "[build-app] 完成：$APP_DIR"
