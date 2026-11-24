#!/usr/bin/env bash
# 造一个「多任务并行」的演示库并启动 app，用来拍 README 的多任务效果图。
#
# ## 为什么必须造数据
# 多任务态要求同时存在 **≥ 2 条** `status='working'` 会话（真实库里长年只有 1 条）。
# 少造一条就看不到标题上的 `(1/2)` 序号，也演示不了「横滑切换、详情一起切」。
#
# 用法：
#   ./Scripts/demo-multi-task.sh            # 用演示库启动（看多任务态）
#   ./Scripts/demo-multi-task.sh --restore  # 切回真实库
#
# 安全性：演示库是真实库的**副本**（`.verify/demo-multi.db`），
#   脚本只改副本，绝不写 `~/.workbuddy/workbuddy.db`。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_DB="$HOME/.workbuddy/workbuddy.db"
DEMO_DB="$ROOT/.verify/demo-multi.db"
APP_BIN="$ROOT/build/WorkBar.app/Contents/MacOS/WorkBar"

# 两条并行任务：id 取自真实库中存在的会话，只改副本里的字段。
SESSION_A="${DEMO_SESSION_A:-c10c20a4-9c44-4110-a320-855ac248f51a}"
SESSION_B="${DEMO_SESSION_B:-f2e2c8dd-6cc1-4d34-a5cc-ce1a37e464a6}"

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
# 同其它演示脚本：必须 `.backup` 而非 `cp`，否则 WAL 里未落盘的写入会丢。
echo "[demo] 备份真实库 -> $DEMO_DB"
rm -f "$DEMO_DB"
sqlite3 "$REAL_DB" ".backup '$DEMO_DB'"

NOW="$(date +%s)000"
# B 稍旧一点：列表按 updated_at DESC 排序，A 会排在第一位，
# 于是首帧展示的就是 `(1/2)`，截图不用先去横滑。
OLDER=$((NOW - 45000))

sqlite3 "$DEMO_DB" <<SQL
UPDATE sessions SET status = 'archived' WHERE id NOT IN ('$SESSION_A', '$SESSION_B');

UPDATE sessions
   SET status = 'working', unread = 0,
       custom_title = '重构设置面板布局',
       model = 'hy4flash',
       updated_at = $NOW, last_activity_at = $NOW
 WHERE id = '$SESSION_A';

UPDATE sessions
   SET status = 'working', unread = 0,
       custom_title = '核对上下文百分比精度',
       model = 'hy4flash-free',
       updated_at = $OLDER, last_activity_at = $OLDER
 WHERE id = '$SESSION_B';

-- 两条不同的上下文占用，证明「详情跟着聚焦任务一起切」不是巧合：
-- A = 35.6%，B = 68.2%，横滑后百分比必须跟着变。
INSERT OR REPLACE INTO session_usage(session_id, used, size, updated_at, credit_json)
  VALUES('$SESSION_A', 107053, 300000, $NOW, NULL);
INSERT OR REPLACE INTO session_usage(session_id, used, size, updated_at, credit_json)
  VALUES('$SESSION_B', 204600, 300000, $OLDER, NULL);
SQL

echo "[demo] 两条并行任务："
sqlite3 -readonly "$DEMO_DB" \
  "SELECT id, status, COALESCE(custom_title, title) FROM sessions WHERE status = 'working';"

echo "[demo] 启动 app（数据源 = 演示库）"
# 步骤目录指到空目录：这条会话在真实 `~/.workbuddy/tasks/<id>/` 里恰好有 4 步且全部完成，
# 会和「进行中」读起来矛盾（详情行显示 `4/4`）。多任务这张图要说明的是序号与横滑，
# 不是步骤，所以把步骤整个隐掉，视觉上也与 README 里的工作态主图一致。
EMPTY_STEPS="$ROOT/.verify/empty-steps"
mkdir -p "$EMPTY_STEPS"
exec env TOUCHBARBUDDY_DB_PATH="$DEMO_DB" TB_TASK_STEPS_ROOT="$EMPTY_STEPS" "$APP_BIN"
