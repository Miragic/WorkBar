#!/usr/bin/env bash
# 在「SwiftPM 不可用」的机器上真实执行单元测试。
#
# 背景：本机 `swift build` / `swift test` 因 `PackageDescription` 模块 ABI 断裂而无法工作
# （manifest 编译产物找不到 `Package.__allocating_init(... swiftLanguageVersions ...)` 符号），
# 并且 Command Line Tools 只随附 `Testing.framework`、没有 `XCTest.framework`。
#
# 做法：
#   1. 把 Sources/TouchBarBuddy 全部源码 + Scripts/Support/XCTestShim.swift（极简 XCTest 子集）
#      + Tests/TouchBarBuddyTests 全部测试文件（去掉 import XCTest / @testable import）编译成
#      **同一个模块**，从而 internal API 直接可见（等价 @testable import）。
#   2. 用 python3 扫描测试文件里的 `func testXxx()`，自动生成 runner 的 main.swift。
#   3. 运行并汇总通过/失败；有失败则退出码非 0。
#
# 用法：bash Scripts/run-tests.sh [--selftest]
#
#   --selftest  注入一条必然失败的断言，验证「测试执行器本身」能正确报红（预期退出码 1）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SELFTEST=0
for arg in "$@"; do
  case "$arg" in
    --selftest) SELFTEST=1 ;;
    -h|--help)
      echo "用法: bash Scripts/run-tests.sh [--selftest]"
      exit 0
      ;;
    *)
      echo "[run-tests] 未知参数: $arg" >&2
      exit 2
      ;;
  esac
done
export TB_SELFTEST="$SELFTEST"
SRC_DIR="$ROOT/Sources/TouchBarBuddy"
TEST_DIR="$ROOT/Tests/TouchBarBuddyTests"
SHIM="$ROOT/Scripts/Support/XCTestShim.swift"

if [ ! -d "$SRC_DIR" ] || [ ! -d "$TEST_DIR" ]; then
  echo "[run-tests] 找不到源码或测试目录" >&2
  exit 1
fi

# SDK：优先用修补版（编译器版本与 SDK 匹配），否则退回系统 SDK。
SDK="$HOME/sdk-fixed/MacOSX.sdk"
if [ ! -d "$SDK" ]; then
  SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
fi
if [ -z "${SDK:-}" ] || [ ! -d "$SDK" ]; then
  echo "[run-tests] 找不到可用 SDK" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tbtests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 1) 复制测试文件并去掉 XCTest / @testable import（同模块编译，internal 直接可见）。
mkdir -p "$WORK/tests"
for f in "$TEST_DIR"/*.swift; do
  [ -e "$f" ] || continue
  sed -e '/^import XCTest[[:space:]]*$/d' -e '/^@testable import TouchBarBuddy[[:space:]]*$/d' \
    "$f" > "$WORK/tests/$(basename "$f")"
done

# 2) 扫描测试方法，生成 runner。
python3 - "$WORK" "$WORK/tests" <<'PY'
import os
import re
import sys

work, tests_dir = sys.argv[1], sys.argv[2]
class_re = re.compile(r'class\s+(\w+)\s*:\s*XCTestCase')
func_re = re.compile(r'^\s*func\s+(test\w+)\s*\(')

entries = []
for name in sorted(os.listdir(tests_dir)):
    if not name.endswith('.swift'):
        continue
    cls = None
    with open(os.path.join(tests_dir, name), encoding='utf-8') as fh:
        for line in fh:
            m = class_re.search(line)
            if m:
                cls = m.group(1)
            m = func_re.match(line)
            if m and cls:
                # 记录是否 throws：只有 throws 方法才需要 do/catch 包裹，
                # 否则会引入 "no calls to throwing functions" 与
                # "catch block is unreachable" 两条噪音警告。
                is_throws = 'throws' in line
                entries.append((cls, m.group(1), is_throws))

if not entries:
    print('[run-tests] 未扫描到任何 test 方法', file=sys.stderr)
    sys.exit(1)

out = []
out.append('import Foundation')
out.append('')
out.append('// 由 Scripts/run-tests.sh 自动生成，请勿手改。')
out.append('')
out.append('typealias TBTestEntry = (name: String, body: () -> Void)')
out.append('')
out.append('let tbAllTests: [TBTestEntry] = [')
for cls, fn, is_throws in entries:
    out.append('    ("%s.%s", {' % (cls, fn))
    out.append('        let t = %s()' % cls)
    out.append('        t.setUp()')
    out.append('        defer { t.tearDown() }')
    if is_throws:
        out.append('        do { try t.%s() } catch { XCTFail("抛出异常: \\(error)") }' % fn)
    else:
        out.append('        t.%s()' % fn)
    out.append('    }),')
# 自检模式：注入一条必然失败的断言，用来证明 harness 真的能发现失败
# （而不是「因为没有检查所以全绿」）。预期结果是 1 个 FAIL、退出码 1。
if os.environ.get('TB_SELFTEST') == '1':
    out.append('    ("HarnessSelfTest.deliberateFailure", {')
    out.append('        XCTAssertEqual(1, 2, "自检：本条失败必须被捕获")')
    out.append('    }),')
out.append(']')
out.append('')
out.append('var tbPassed = 0')
out.append('var tbFailed: [String] = []')
out.append('for entry in tbAllTests {')
out.append('    let before = XCTestSupport.failures.count')
out.append('    XCTestSupport.currentTest = entry.name')
out.append('    entry.body()')
out.append('    let newFailures = XCTestSupport.failures[before...]')
out.append('    if newFailures.isEmpty {')
out.append('        tbPassed += 1')
out.append('        print("  PASS  \\(entry.name)")')
out.append('    } else {')
out.append('        tbFailed.append(entry.name)')
out.append('        print("  FAIL  \\(entry.name)")')
out.append('        for f in newFailures {')
out.append('            print("        \\(f.file):\\(f.line)  \\(f.message)")')
out.append('        }')
out.append('    }')
out.append('}')
out.append('')
out.append('print("")')
out.append('print("共 \\(tbAllTests.count) 个测试：通过 \\(tbPassed)，失败 \\(tbFailed.count)")')
out.append('exit(tbFailed.isEmpty ? 0 : 1)')

with open(os.path.join(work, 'main.swift'), 'w', encoding='utf-8') as fh:
    fh.write('\n'.join(out) + '\n')

print('[run-tests] 扫描到 %d 个测试方法' % len(entries))
PY
gen_status=$?
if [ $gen_status -ne 0 ]; then
  exit $gen_status
fi

# 3) 同模块编译（源码 + shim + 测试 + runner）。
SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <(find "$SRC_DIR" -name '*.swift' | sort)
TESTS=()
while IFS= read -r line; do TESTS+=("$line"); done < <(find "$WORK/tests" -name '*.swift' | sort)

echo "[run-tests] 编译 $(( ${#SOURCES[@]} + ${#TESTS[@]} + 2 )) 个文件 ..."
swiftc -sdk "$SDK" \
  -o "$WORK/tb-tests" \
  -lsqlite3 \
  "${SOURCES[@]}" "$SHIM" "${TESTS[@]}" "$WORK/main.swift"
build_status=$?
if [ "$build_status" -ne 0 ]; then
  echo "[run-tests] 编译失败（退出码 ${build_status}）" >&2
  exit "$build_status"
fi

# 4) 运行。
echo "[run-tests] 运行测试 ..."
"$WORK/tb-tests"
exit $?
