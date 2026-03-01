#!/usr/bin/env bash
# VibeGuard Hook 日志模块
#
# 所有 hook 脚本 source 此文件，使用 vg_log 记录事件到 JSONL 文件。
# 日志路径：~/.vibeguard/events.jsonl
#
# 用法：
#   source "$(dirname "$0")/log.sh"
#   vg_log "pre-bash-guard" "Bash" "block" "force push" "git push --force"
#   vg_log "post-edit-guard" "Edit" "warn" "unwrap detected" "src/main.rs"
#   vg_log "pre-write-guard" "Write" "pass" "" "src/lib.rs"
#
# 支持的 decision 类型：
#   pass     — 检查通过，放行
#   warn     — 检测到问题，警告但不阻止
#   block    — 严重问题，阻止操作
#   gate     — 门禁触发，需要用户确认
#   escalate — 升级警告，同一问题多次 warn 后自动升级
#   complete — 操作完成确认

VIBEGUARD_LOG_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
VIBEGUARD_LOG_FILE="${VIBEGUARD_LOG_DIR}/events.jsonl"

# 源码文件扩展名列表（共享常量）
VG_SOURCE_EXTS="rs py ts js tsx jsx go java kt swift rb"

# 判断文件是否为源码文件
# 用法: vg_is_source_file "path/to/file.rs" && echo "是源码"
vg_is_source_file() {
  local file_path="$1"
  local basename ext
  basename=$(basename "$file_path")
  ext="${basename##*.}"
  for e in $VG_SOURCE_EXTS; do
    if [[ "$ext" == "$e" ]]; then
      return 0
    fi
  done
  return 1
}

# 从 stdin JSON 中提取指定字段
# 用法: value=$(echo "$INPUT" | vg_json_field "tool_input.file_path")
vg_json_field() {
  local field_path="$1"
  python3 -c "
import json, sys
data = json.load(sys.stdin)
keys = '${field_path}'.split('.')
val = data
for k in keys:
    if isinstance(val, dict):
        val = val.get(k, '')
    else:
        val = ''
        break
print(val if isinstance(val, str) else '')
" 2>/dev/null || echo ""
}

# 从 stdin JSON 中提取两个字段，用 NUL 分隔（安全替代 ---SEPARATOR---）
# 用法: read_result=$(echo "$INPUT" | vg_json_two_fields "tool_input.file_path" "tool_input.content")
#        FILE_PATH=$(echo "$read_result" | head -1)
#        CONTENT=$(echo "$read_result" | tail -n +2)
vg_json_two_fields() {
  local field1="$1"
  local field2="$2"
  python3 -c "
import json, sys
data = json.load(sys.stdin)

def get_nested(d, path):
    keys = path.split('.')
    val = d
    for k in keys:
        if isinstance(val, dict):
            val = val.get(k, '')
        else:
            return ''
    return val if isinstance(val, str) else ''

f1 = get_nested(data, '${field1}')
f2 = get_nested(data, '${field2}')
# 第一行是 field1，其余是 field2（field2 可能多行）
print(f1)
print(f2)
" 2>/dev/null || echo ""
}

# Session ID：同一个 Claude Code 会话内的事件共享同一个 session_id
# 优先使用环境变量，否则按 PID 树推导（同一终端会话的父进程 PID 相同）
VIBEGUARD_SESSION_ID="${VIBEGUARD_SESSION_ID:-$(echo "$$-$(date +%Y%m%d)" | shasum | cut -c1-8)}"

# 计时器：在 hook 开头调用 vg_start_timer，vg_log 自动计算耗时
_VG_START_MS=""
vg_start_timer() {
  if command -v perl &>/dev/null; then
    _VG_START_MS=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
  elif command -v python3 &>/dev/null; then
    _VG_START_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
  else
    _VG_START_MS=$(date +%s)000
  fi
}

vg_log() {
  local hook="$1"
  local tool="$2"
  local decision="$3"
  local reason="${4:-}"
  local detail="${5:-}"

  # 计算耗时
  local duration_ms=""
  if [[ -n "$_VG_START_MS" ]]; then
    local end_ms
    if command -v perl &>/dev/null; then
      end_ms=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
    elif command -v python3 &>/dev/null; then
      end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
    else
      end_ms=$(date +%s)000
    fi
    duration_ms=$(( end_ms - _VG_START_MS ))
    _VG_START_MS=""
  fi

  mkdir -p "$VIBEGUARD_LOG_DIR"
  chmod 700 "$VIBEGUARD_LOG_DIR" 2>/dev/null || true

  VG_HOOK="$hook" VG_TOOL="$tool" VG_DECISION="$decision" \
  VG_REASON="$reason" VG_DETAIL="$detail" VG_LOG_FILE="$VIBEGUARD_LOG_FILE" \
  VG_SESSION_ID="$VIBEGUARD_SESSION_ID" VG_DURATION_MS="${duration_ms:-}" \
  VG_AGENT_TYPE="${VIBEGUARD_AGENT_TYPE:-}" \
  python3 -c '
import json, datetime, os, re

detail = os.environ.get("VG_DETAIL", "").strip()[:200]
# 脱敏：移除 Bearer token、密钥、密码等敏感信息
detail = re.sub(
    r"(Authorization|Bearer|token|password|secret|key|apikey|api_key)"
    r"[\s:=]+\S+",
    r"\1=[REDACTED]",
    detail,
    flags=re.IGNORECASE,
)

event = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "session": os.environ.get("VG_SESSION_ID", ""),
    "hook": os.environ.get("VG_HOOK", ""),
    "tool": os.environ.get("VG_TOOL", ""),
    "decision": os.environ.get("VG_DECISION", ""),
    "reason": os.environ.get("VG_REASON", "").strip(),
    "detail": detail,
}
# 可选字段：仅在有值时写入
duration = os.environ.get("VG_DURATION_MS", "")
if duration:
    event["duration_ms"] = int(duration)
agent_type = os.environ.get("VG_AGENT_TYPE", "")
if agent_type:
    event["agent"] = agent_type

log_file = os.environ["VG_LOG_FILE"]
with open(log_file, "a") as f:
    f.write(json.dumps(event, ensure_ascii=False) + "\n")
import os as _os
_os.chmod(log_file, 0o600)
' 2>/dev/null || true
}
