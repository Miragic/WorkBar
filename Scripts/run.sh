#!/usr/bin/env bash
# 一键构建并运行 WorkBar.app。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 用 build-direct.sh 而不是 build-app.sh：
#   本机 CommandLineTools 的 swiftc 与 libPackageDescription 版本不匹配，
#   `swift build` 会在链接 Package.swift 清单时因 Undefined symbols 失败。
#   build-direct.sh 直接调 swiftc 编译，绕开 SwiftPM，是本机唯一可用的构建路径。
"$ROOT/Scripts/build-direct.sh"

echo "[run] open $ROOT/build/WorkBar.app"
open "$ROOT/build/WorkBar.app"
