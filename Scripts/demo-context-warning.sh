#!/usr/bin/env bash
# 造一个「上下文快满了」的演示库并启动 app，用来肉眼验证橙色警告态。
#
# 为什么需要这个脚本：
#   真实库里 `session_usage` 最满的一行也只有 74.45%（阈值是 75%），
#   所以 `⚠️` 橙色态几乎不可能自然触发 —— 不造数据就永远测不到这条分支。
#
# 用法：
#   ./Scripts/demo-context-warning.sh            # 用演示库启动（看橙色态）
#   ./Scripts/demo-context-warning.sh --restore  # 切回真实库
#
# 安全性：演示库是真实库的**副本**（.verify/demo-warning.db），
#   脚本只改副本，绝不写 `~/.workbuddy/workbuddy.db`。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_DB="$HOME/.workbuddy/workbuddy.db"
DEMO_DB="$ROOT/.verify/demo-warning.db"
APP_BIN="$ROOT/build/WorkBar.app/Contents/MacOS/WorkBar"

# 单实例保护：旧实例不退，`open` 只会激活它，于是「改了代码却看不到新版本」。
kill_existing() {
  pkill -f "WorkBar.app/Contents/MacOS/WorkBar" 2>/dev/null || true
  sleep 1
}

if [[ ! -x "$APP_BIN" ]]; then
  echo "[demo] 未找到 $APP_BIN，先跑 ./Scripts/build-direct.sh" >&2
  exit 1
fi

kill_existing

if [[ "${1:-}" == "--restore" ]]; then
  echo "[demo] 切回真实库：$REAL_DB"
  open "$ROOT/build/WorkBar.app"
  sleep 2
  grep "数据源" "$HOME/Library/Logs/WorkBar.log" | tail -1
  exit 0
fi

if [[ ! -f "$REAL_DB" ]]; then
  echo "[demo] 未找到真实库 $REAL_DB" >&2
  exit 1
fi

# 取当前正在进行中的会话：优先 working，其次 active，确保 Touch Bar 一定展示它。
SESSION_ID="$(sqlite3 -readonly "$REAL_DB" \
  "SELECT id FROM sessions WHERE status IN ('working','active') AND deleted_at IS NULL ORDER BY updated_at DESC LIMIT 1;")"
if [[ -z "$SESSION_ID" ]]; then
  echo "[demo] 真实库里没有 working / active 会话，无法造演示数据" >&2
  exit 1
fi

echo "[demo] 复制真实库 -> $DEMO_DB"
mkdir -p "$ROOT/.verify"
cp "$REAL_DB" "$DEMO_DB"

NOW="$(date +%s)000"
# 把上下文占用拉到 92%（超过 75% 阈值），并把时间戳刷成"刚刚"，
# 避免副库里冻结的时间让任务条显示「疑似卡住」而干扰观察。
sqlite3 "$DEMO_DB" <<SQL
UPDATE sessions
   SET custom_title = '上下文演示', updated_at = $NOW, last_activity_at = $NOW
 WHERE id = '$SESSION_ID';
INSERT OR REPLACE INTO session_usage(session_id, used, size, updated_at, credit_json)
VALUES('$SESSION_ID', 552000, 600000, $NOW, NULL);
SQL

echo "[demo] 演示会话 $SESSION_ID 上下文 = 92%"
echo "[demo] 启动 app（数据源 = 演示库）"
echo "[demo] 注意：open --env 在本机不生效，必须直接执行二进制才能传环境变量"
TOUCHBARBUDDY_DB_PATH="$DEMO_DB" exec "$APP_BIN"
