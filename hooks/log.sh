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

vg_log() {
  local hook="$1"
  local tool="$2"
  local decision="$3"
  local reason="${4:-}"
  local detail="${5:-}"

  mkdir -p "$VIBEGUARD_LOG_DIR"
  chmod 700 "$VIBEGUARD_LOG_DIR" 2>/dev/null || true

  VG_HOOK="$hook" VG_TOOL="$tool" VG_DECISION="$decision" \
  VG_REASON="$reason" VG_DETAIL="$detail" VG_LOG_FILE="$VIBEGUARD_LOG_FILE" \
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
    "hook": os.environ.get("VG_HOOK", ""),
    "tool": os.environ.get("VG_TOOL", ""),
    "decision": os.environ.get("VG_DECISION", ""),
    "reason": os.environ.get("VG_REASON", "").strip(),
    "detail": detail,
}
log_file = os.environ["VG_LOG_FILE"]
with open(log_file, "a") as f:
    f.write(json.dumps(event, ensure_ascii=False) + "\n")
import os as _os
_os.chmod(log_file, 0o600)
' 2>/dev/null || true
}
