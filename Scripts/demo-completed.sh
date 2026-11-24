#!/usr/bin/env bash
# 造一个「任务已完成」的演示库并启动 app，用来拍 README 的完成态效果图。
#
# ## 为什么必须造数据
# 完成态对应 `.unread`（`status='completed' AND unread != 0`）。
# 但真实库里 **55 条 completed 会话的 unread 全是 0**（WorkBuddy 从不写未读标记），
# 这条分支在真实使用中永远不触发 —— 不造数据根本拍不到。
#
# ## 口径说明（别被这张图骗了）
# 这张图展示的是「如果 WorkBuddy 写了未读标记」的样子，属于前向兼容分支的可视化，
# 不是当前版本的常态。README 里必须如实标注，否则等于宣传一个不存在的功能。
#
# 用法：
#   ./Scripts/demo-completed.sh            # 用演示库启动（看完成态）
#   ./Scripts/demo-completed.sh --restore  # 切回真实库
#
# 安全性：演示库是真实库的**副本**（`.verify/demo-completed.db`），
#   脚本只改副本，绝不写 `~/.workbuddy/workbuddy.db`。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_DB="$HOME/.workbuddy/workbuddy.db"
DEMO_DB="$ROOT/.verify/demo-completed.db"
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
# 用 `.backup` 而不是 `cp`：库可能处于 WAL 模式，直接拷主文件会丢最近的写入
# （之前用 cp 造场景时遇到过「副本里会话存在但 app 读到 0 条」）。
echo "[demo] 备份真实库 -> $DEMO_DB"
rm -f "$DEMO_DB"
sqlite3 "$REAL_DB" ".backup '$DEMO_DB'"

NOW="$(date +%s)000"

# 只留一条「已完成」会话，其余全部归档：
# 归约优先级是 待确认 > 进行中 > 待读，库里只要还有一条 working 会话，
# 完成态就永远轮不到展示（真实库里恰好有一条 working）。
sqlite3 "$DEMO_DB" <<SQL
UPDATE sessions SET status = 'archived' WHERE id <> '$SESSION_ID';
UPDATE sessions
   SET status = 'completed',
       unread = 1,
       custom_title = '为 WorkBar 设计 Touch Bar 图标',
       model = 'hy4flash',
       updated_at = $NOW,
       last_activity_at = $NOW
 WHERE id = '$SESSION_ID';
SQL

echo "[demo] 已完成态会话：$SESSION_ID"
sqlite3 -readonly "$DEMO_DB" \
  "SELECT status, unread, COALESCE(custom_title, title) FROM sessions WHERE id = '$SESSION_ID';"

echo "[demo] 启动 app（数据源 = 演示库）"
# 必须直接执行二进制：`open --env` 在本机不生效，环境变量传不进去。
exec env TOUCHBARBUDDY_DB_PATH="$DEMO_DB" "$APP_BIN"
