#!/usr/bin/env bash
# VibeGuard PostToolUse(Edit|Write) Hook — 编辑后自动构建检查
#
# 编辑源码文件后自动运行对应语言的构建检查：
#   - Rust (.rs): cargo check
#   - TypeScript (.ts/.tsx): npx tsc --noEmit
#   - JavaScript (.js/.mjs/.cjs): node --check
#   - Go (.go): go build ./...
#
# 安全层：
#   - CI 守卫：$CI 环境下跳过（避免 CI 中的无限循环 #3573）
#   - 断路器：连续 ≥3 次构建失败后进入 OPEN 状态，5分钟冷却期内自动放行
#
# 只输出警告，不阻止操作。

set -euo pipefail

source "$(dirname "$0")/log.sh"

# --- CI 守卫：CI 环境跳过桌面 hook，防止 #3573 类无限循环 ---
if [[ -n "${CI:-}" ]]; then
  exit 0
fi

INPUT=$(cat)

# 从 Edit 或 Write 的 JSON 中提取 file_path
FILE_PATH=$(echo "$INPUT" | vg_json_field "tool_input.file_path")

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# 获取文件扩展名
BASENAME=$(basename "$FILE_PATH")
EXT="${BASENAME##*.}"

# 只处理需要构建检查的语言
case "$EXT" in
  rs|ts|tsx|go|js|mjs|cjs) ;;
  *) exit 0 ;;
esac

# === 断路器（Circuit Breaker） ===
# Martin Fowler 模式：CLOSED → OPEN（冷却期自动放行）→ HALF-OPEN（探测一次）
# 状态持久化到项目日志目录，避免不同项目互相影响
CB_STATE_FILE="${VIBEGUARD_PROJECT_LOG_DIR}/cb_build_check.json"
CB_COOLDOWN_SECS=300  # 5 分钟冷却期
CB_THRESHOLD=3        # 连续失败次数触发阈值

cb_get_state() {
  CB_STATE_FILE="$CB_STATE_FILE" CB_COOLDOWN_SECS="$CB_COOLDOWN_SECS" python3 - <<'PYEOF'
import json, time, os, sys
f = os.environ.get("CB_STATE_FILE", "")
cooldown = int(os.environ.get("CB_COOLDOWN_SECS", "300"))
try:
    with open(f) as fh:
        d = json.load(fh)
    state = d.get("state", "closed")
    if state == "open":
        if time.time() - d.get("opened_at", 0) >= cooldown:
            print("half-open")
        else:
            print("open")
    else:
        print(state)
except FileNotFoundError:
    print("closed")  # 首次运行，正常情况
except Exception as e:
    print(f"[post-build-check] cb_get_state: state-file={f!r} error={e}", file=sys.stderr)
    print("closed")  # 降级为安全默认值，但已记录错误
PYEOF
}

cb_set_open() {
  CB_STATE_FILE="$CB_STATE_FILE" CB_COOLDOWN_SECS="$CB_COOLDOWN_SECS" python3 - <<'PYEOF'
import json, time, os, sys
f = os.environ.get("CB_STATE_FILE", "")
cooldown = int(os.environ.get("CB_COOLDOWN_SECS", "300"))
try:
    with open(f, "w") as fh:
        json.dump({"state": "open", "opened_at": time.time(), "cooldown_secs": cooldown}, fh)
except Exception as e:
    print(f"[post-build-check] cb_set_open: state-file={f!r} error={e}", file=sys.stderr)
PYEOF
}

cb_set_closed() {
  CB_STATE_FILE="$CB_STATE_FILE" python3 - <<'PYEOF'
import json, os, sys
f = os.environ.get("CB_STATE_FILE", "")
try:
    with open(f, "w") as fh:
        json.dump({"state": "closed", "opened_at": 0}, fh)
except Exception as e:
    print(f"[post-build-check] cb_set_closed: state-file={f!r} error={e}", file=sys.stderr)
PYEOF
}

# 检查当前断路器状态
CB_CURRENT_STATE=$(cb_get_state)

if [[ "$CB_CURRENT_STATE" == "open" ]]; then
  # 断路器开启，冷却期内自动放行（避免分析瘫痪）
  vg_log "post-build-check" "Edit" "pass" "[CB:OPEN] 断路器冷却中，自动放行" "$FILE_PATH"
  exit 0
fi

# 向上查找项目根目录（根据语言查找不同的标记文件）
find_project_root() {
  local dir="$1"
  local marker="$2"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/$marker" ]]; then
      echo "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

ERRORS=""

case "$EXT" in
  rs)
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "Cargo.toml") || exit 0
    ERRORS=$(cd "$PROJECT_ROOT" && cargo check --message-format=short 2>&1 | grep -E "^error" | head -10) || true
    ;;
  ts|tsx)
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "tsconfig.json") || exit 0
    ERRORS=$(cd "$PROJECT_ROOT" && npx tsc --noEmit 2>&1 | grep -E "error TS" | head -10) || true
    ;;
  js|mjs|cjs)
    command -v node >/dev/null 2>&1 || exit 0
    ERRORS=$(node --check "$FILE_PATH" 2>&1 | head -10) || true
    ;;
  go)
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "go.mod") || exit 0
    ERRORS=$(cd "$PROJECT_ROOT" && go build ./... 2>&1 | head -10) || true
    ;;
esac

if [[ -z "$ERRORS" ]]; then
  # 构建通过：如果当前是 half-open 探测，关闭断路器
  if [[ "$CB_CURRENT_STATE" == "half-open" ]]; then
    cb_set_closed
  fi
  vg_log "post-build-check" "Edit" "pass" "" "$FILE_PATH"
  exit 0
fi

ERROR_COUNT=$(echo "$ERRORS" | wc -l | tr -d ' ')
WARNINGS="[BUILD] 编辑 ${BASENAME} 后检测到 ${ERROR_COUNT} 个构建错误：
${ERRORS}"

# --- 连续失败计数（用于断路器和 escalation）---
CONSECUTIVE_FAILS=$(VG_LOG_FILE="$VIBEGUARD_LOG_FILE" python3 -c '
import json, os
log_file = os.environ.get("VG_LOG_FILE", "")
count = 0
try:
    with open(log_file) as f:
        lines = f.readlines()
    for line in reversed(lines):
        line = line.strip()
        if not line: continue
        try:
            e = json.loads(line)
            if e.get("hook") != "post-build-check": continue
            if e.get("decision") == "pass":
                break
            if e.get("decision") in ("warn", "escalate"):
                count += 1
        except: continue
except: pass
print(count)
' 2>/dev/null | tr -d '[:space:]' || echo "0")
# +1 to count the current failure (not yet written to log at this point)
CONSECUTIVE_FAILS=$(( ${CONSECUTIVE_FAILS:-0} + 1 ))

DECISION="warn"

# --- 断路器：half-open 探测失败 → 重新开启；CLOSED 连续失败 ≥ 阈值 → 开启 ---
if [[ "$CB_CURRENT_STATE" == "half-open" ]]; then
  cb_set_open
  DECISION="escalate"
  WARNINGS="[CB:HALF-OPEN→OPEN] 断路器探测失败，重新进入冷却期（${CB_COOLDOWN_SECS}s）。${WARNINGS}"
elif [[ "$CONSECUTIVE_FAILS" -ge "$CB_THRESHOLD" ]]; then
  cb_set_open
  DECISION="escalate"
  WARNINGS="[CB:CLOSED→OPEN] 连续 ${CONSECUTIVE_FAILS} 次构建失败，断路器开启。冷却期 ${CB_COOLDOWN_SECS}s 内后续编辑自动放行，避免无限循环。${WARNINGS}"
fi

# --- U-25 escalation: 独立检查，不受断路器阈值屏蔽 ---
if [[ "$CONSECUTIVE_FAILS" -ge 5 ]]; then
  DECISION="escalate"
  WARNINGS="[U-25 ESCALATE] 连续 ${CONSECUTIVE_FAILS} 次构建失败！必须先修复构建错误再继续编辑。建议：运行完整构建命令查看全部错误，定位根因一次性修复。${WARNINGS}"
fi

vg_log "post-build-check" "Edit" "$DECISION" "构建错误 ${ERROR_COUNT} 个（连续 ${CONSECUTIVE_FAILS} 次）" "$FILE_PATH"

VG_WARNINGS="$WARNINGS" VG_DECISION="$DECISION" python3 -c '
import json, os
warnings = os.environ.get("VG_WARNINGS", "")
decision = os.environ.get("VG_DECISION", "warn")
if decision == "escalate":
    prefix = "VIBEGUARD 构建升级警告"
else:
    prefix = "VIBEGUARD 构建检查"
result = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": prefix + "：" + warnings
    }
}
print(json.dumps(result, ensure_ascii=False))
'