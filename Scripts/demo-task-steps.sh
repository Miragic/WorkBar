#!/usr/bin/env bash
# 演示 V12「任务步骤」：造一份待办清单副本并让 app 去读它。
#
# 为什么需要脚本：
#   只有用过待办清单的会话才有 `~/.workbuddy/tasks/<session>/*.json`（实测 16/54），
#   当前开发会话没有。不造数据就看不到 `3/8 …` 那一段。
#
# 用法：
#   ./Scripts/demo-task-steps.sh            # 造 8 步（3 完成 / 1 进行中）并启动
#   ./Scripts/demo-task-steps.sh --restore  # 切回读取真实步骤目录
#
# 安全性：只写 `.verify/demo-steps/<当前会话id>/`，**不碰** `~/.workbuddy/tasks/`。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_DB="$HOME/.workbuddy/workbuddy.db"
DEMO_ROOT="$ROOT/.verify/demo-steps"
APP_BIN="$ROOT/build/WorkBar.app/Contents/MacOS/WorkBar"

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
  echo "[demo] 切回真实步骤目录 ~/.workbuddy/tasks"
  open "$ROOT/build/WorkBar.app"
  exit 0
fi

SESSION_ID="$(sqlite3 -readonly "$REAL_DB" \
  "SELECT id FROM sessions WHERE status IN ('working','active') AND deleted_at IS NULL ORDER BY updated_at DESC LIMIT 1;")"
if [[ -z "$SESSION_ID" ]]; then
  echo "[demo] 真实库里没有 working / active 会话" >&2
  exit 1
fi

DIR="$DEMO_ROOT/$SESSION_ID"
mkdir -p "$DIR"
NOW="$(date +%s)000"

python3 - "$DIR" "$NOW" <<'PY'
import json, os, sys
directory, now = sys.argv[1], int(sys.argv[2])
subjects = ["梳理现有状态机", "确定数据源方案", "实现上下文指示", "核对百分比精度",
            "补充步骤显示", "真机回归验证", "更新开发文档", "跑完整测试"]
for i, subject in enumerate(subjects, 1):
    status = "completed" if i <= 3 else ("in_progress" if i == 4 else "pending")
    obj = {"subject": subject, "description": "", "activeForm": subject,
           "status": status, "id": str(i),
           "createdAt": now - 3600000 + i * 1000,
           "updatedAt": now - 3600000 + i * 1000}
    with open(os.path.join(directory, f"{i}.json"), "w") as f:
        json.dump(obj, f, ensure_ascii=False)
print(f"[demo] 已造 {len(subjects)} 步：3 完成 / 1 进行中（{subjects[3]}）")
PY

# 关掉 open，必须直接执行二进制才能传环境变量（实测 open --env 不生效）。
echo "[demo] 启动 app（步骤目录 = $DEMO_ROOT）"
echo "[demo] 需要打开设置里的「任务步骤」，并在详情视图才能看到 3/8 那一段"
exec env TB_TASK_STEPS_ROOT="$DEMO_ROOT" "$APP_BIN"
