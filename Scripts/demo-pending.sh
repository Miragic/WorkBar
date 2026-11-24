#!/usr/bin/env bash
# 造一个「待确认」的演示库并启动 app，用来拍 README 的待确认态效果图。
#
# ## 为什么必须造数据
# 待确认态要求 `sessions.status = 'pending'`。真实库里当前一条都没有
# （只有 completed / archived / working），不造数据就拍不到这一屏。
#
# 用法：
#   ./Scripts/demo-pending.sh            # 用演示库启动（看待确认态）
#   ./Scripts/demo-pending.sh --restore  # 切回真实库
#
# 安全性：演示库是真实库的**副本**（`.verify/demo-pending.db`），
#   脚本只改副本，绝不写 `~/.workbuddy/workbuddy.db`。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_DB="$HOME/.workbuddy/workbuddy.db"
DEMO_DB="$ROOT/.verify/demo-pending.db"
APP_BIN="$ROOT/build/WorkBar.app/Contents/MacOS/WorkBar"
SESSION_ID="${DEMO_SESSION_ID:-c10c20a4-9c44-4110-a320-855ac248f51a}"

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

mkdir -p "$ROOT/.verify"
# 同 demo-completed.sh：必须用 `.backup` 而非 `cp`，否则 WAL 里未落盘的写入会丢。
echo "[demo] 备份真实库 -> $DEMO_DB"
rm -f "$DEMO_DB"
sqlite3 "$REAL_DB" ".backup '$DEMO_DB'"

NOW="$(date +%s)000"

# 归约优先级 待确认 > 进行中 > 待读：先把其它会话全部归档，
# 否则真实库里那条 working 会话会盖掉待确认态。
sqlite3 "$DEMO_DB" <<SQL
UPDATE sessions SET status = 'archived' WHERE id <> '$SESSION_ID';
UPDATE sessions
   SET status = 'pending',
       unread = 0,
       custom_title = '等待确认：重构设置面板布局',
       model = 'hy4flash',
       updated_at = $NOW,
       last_activity_at = $NOW
 WHERE id = '$SESSION_ID';
SQL

echo "[demo] 待确认态会话：$SESSION_ID"
sqlite3 -readonly "$DEMO_DB" \
  "SELECT status, unread, COALESCE(custom_title, title) FROM sessions WHERE id = '$SESSION_ID';"

echo "[demo] 启动 app（数据源 = 演示库）"
exec env TOUCHBARBUDDY_DB_PATH="$DEMO_DB" "$APP_BIN"
