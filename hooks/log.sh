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

# 按项目隔离日志：用 git repo 根目录路径的哈希区分不同项目
_vg_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "global")
_vg_project_hash=$(printf '%s' "$_vg_repo_root" | shasum -a 256 2>/dev/null | cut -c1-8) || _vg_project_hash="fallback0"
VIBEGUARD_PROJECT_LOG_DIR="${VIBEGUARD_LOG_DIR}/projects/${_vg_project_hash}"
mkdir -p "$VIBEGUARD_PROJECT_LOG_DIR" 2>/dev/null
VIBEGUARD_LOG_FILE="${VIBEGUARD_PROJECT_LOG_DIR}/events.jsonl"

# 记录 hash → 项目路径映射（供 GC 学习阶段使用）
if [[ "$_vg_repo_root" != "global" ]]; then
  printf '%s' "$_vg_repo_root" > "$VIBEGUARD_PROJECT_LOG_DIR/.project-root" 2>/dev/null || true
fi

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
# 策略：祖先进程 PID + 30 分钟不活跃窗口 + 进程启动时间锚定
# - PID 隔离：并行 Claude 实例各有独立 session_id
# - 30min TTL：同一进程的不同任务（间隔 >30min）产生新 session_id，防止跨任务污染
# - 进程启动时间锚定：防止 PID 回收导致旧 session_id 被继承（ps -o comm 无法区分同名新进程）
if [[ -z "${VIBEGUARD_SESSION_ID:-}" ]]; then
  # Walk up the process tree to find the ancestor Claude Code (node/Electron) process.
  # Each parallel Claude Code instance has a unique PID, so this gives true per-instance isolation.
  _vg_claude_pid=""
  _vg_walk_pid="$$"
  _vg_depth=0
  while [[ $_vg_depth -lt 8 ]]; do
    _vg_ppid=$(ps -o ppid= -p "$_vg_walk_pid" 2>/dev/null | tr -d ' ') || break
    [[ -z "$_vg_ppid" || "$_vg_ppid" == "0" || "$_vg_ppid" == "1" ]] && break
    _vg_comm=$(ps -o comm= -p "$_vg_ppid" 2>/dev/null | tr -d ' ') || break
    case "$_vg_comm" in
      node|*claude*|*Claude*|*electron*|*Electron*)
        _vg_claude_pid="$_vg_ppid"
        break
        ;;
    esac
    _vg_walk_pid="$_vg_ppid"
    _vg_depth=$((_vg_depth + 1))
  done

  if [[ -n "$_vg_claude_pid" ]]; then
    # Capture the process start time as a stable identity anchor.
    # ps -o lstart= returns a fixed timestamp for the process lifetime, unlike comm which only
    # checks the name — a recycled PID can have a new process with the same name but a different
    # start time, allowing us to detect the recycling and create a fresh session.
    # TZ=UTC is forced so the lstart string is timezone-independent: the same PID always
    # produces the same string regardless of the user's TZ setting, DST transitions, or
    # whether hooks inherit different TZ values across invocations.
    _vg_proc_start=$(TZ=UTC ps -o lstart= -p "$_vg_claude_pid" 2>/dev/null | xargs || echo "unknown")

    _vg_sf="${VIBEGUARD_LOG_DIR}/.session_pid_${_vg_claude_pid}"

    # Reuse conditions (all three must hold):
    # 1. Session file exists
    # 2. Within 30-minute inactivity window — long-lived Claude processes run many tasks; the TTL
    #    ensures separate conversations (idle gap > 30 min) get distinct session IDs so that
    #    warn/escalate counters and skills-loaded flags do not leak across tasks.
    # 3. Stored start time matches current process start time — guards against PID recycling where
    #    a new Claude/node process inherits the same PID as the previous one.
    _vg_reuse=false
    if [[ -f "$_vg_sf" ]] && [[ -n "$(find "$_vg_sf" -mmin -30 2>/dev/null)" ]]; then
      _vg_stored_start=$(head -1 "$_vg_sf" 2>/dev/null)
      if [[ "$_vg_stored_start" == "$_vg_proc_start" ]]; then
        _vg_reuse=true
      fi
    fi

    if [[ "$_vg_reuse" == "true" ]]; then
      VIBEGUARD_SESSION_ID=$(tail -1 "$_vg_sf" 2>/dev/null)
      touch "$_vg_sf" 2>/dev/null || true
    else
      # New session: first use, 30-min TTL expired, or PID recycled (start time mismatch).
      VIBEGUARD_SESSION_ID=$(printf '%04x%04x' $RANDOM $RANDOM)
      mkdir -p "$VIBEGUARD_LOG_DIR" 2>/dev/null
      # Atomic write: write to a temp file then rename so concurrent hook invocations
      # sharing the same Claude parent PID never observe a partially-written file.
      # Without this, a reader that runs between the open(O_TRUNC) and the final write
      # of the second line would see an empty or single-line file and use the start-time
      # string (line 1) as the session_id, corrupting all per-session counters/flags.
      # File format: line 1 = process start time anchor (UTC), line 2 = session_id
      _vg_tmp=$(mktemp "${VIBEGUARD_LOG_DIR}/.session_tmp_XXXXXX" 2>/dev/null) \
        || _vg_tmp="${_vg_sf}.tmp.$$"
      printf '%s\n%s\n' "$_vg_proc_start" "$VIBEGUARD_SESSION_ID" > "$_vg_tmp" \
        && mv "$_vg_tmp" "$_vg_sf" 2>/dev/null \
        || { rm -f "$_vg_tmp" 2>/dev/null; printf '%s\n%s\n' "$_vg_proc_start" "$VIBEGUARD_SESSION_ID" > "$_vg_sf"; }
    fi

    # Clean up PID session files older than 2 hours to prevent unbounded disk growth.
    find "${VIBEGUARD_LOG_DIR}" -name ".session_pid_*" -mmin +120 -delete 2>/dev/null || true
  else
    # Fallback for non-Claude Code environments (CI, manual invocation, etc.):
    # time-based 30-minute session window (original behavior).
    _vg_sf="${VIBEGUARD_LOG_DIR}/.session_id"
    if [[ -f "$_vg_sf" ]] && [[ -n "$(find "$_vg_sf" -mmin -30 2>/dev/null)" ]]; then
      VIBEGUARD_SESSION_ID=$(<"$_vg_sf")
      touch "$_vg_sf" 2>/dev/null || true
    else
      VIBEGUARD_SESSION_ID=$(printf '%04x%04x' $RANDOM $RANDOM)
      mkdir -p "$VIBEGUARD_LOG_DIR" 2>/dev/null
      printf '%s' "$VIBEGUARD_SESSION_ID" > "$_vg_sf"
    fi
  fi
fi

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

  # Truncate detail to 200 chars
  detail="${detail:0:200}"

  # 计算耗时
  local duration_ms=""
  if [[ -n "$_VG_START_MS" ]]; then
    local end_ms
    if command -v perl &>/dev/null; then
      end_ms=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
    else
      end_ms=$(date +%s)000
    fi
    duration_ms=$(( end_ms - _VG_START_MS ))
    _VG_START_MS=""
  fi

  mkdir -p "$VIBEGUARD_LOG_DIR" 2>/dev/null
  chmod 700 "$VIBEGUARD_LOG_DIR" 2>/dev/null || true

  # Pure bash JSON serialization（消除 python3 子进程）
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # JSON escape: reason 和 detail 可能含特殊字符
  local esc_reason="${reason//\\/\\\\}" esc_detail="${detail//\\/\\\\}"
  esc_reason="${esc_reason//\"/\\\"}" esc_detail="${esc_detail//\"/\\\"}"
  esc_reason="${esc_reason//$'\n'/\\n}" esc_detail="${esc_detail//$'\n'/\\n}"
  esc_reason="${esc_reason//$'\t'/\\t}" esc_detail="${esc_detail//$'\t'/\\t}"

  local json
  json="{\"ts\": \"${ts}\", \"session\": \"${VIBEGUARD_SESSION_ID}\", \"hook\": \"${hook}\", \"tool\": \"${tool}\", \"decision\": \"${decision}\", \"reason\": \"${esc_reason}\", \"detail\": \"${esc_detail}\""
  [[ -n "$duration_ms" ]] && json="${json}, \"duration_ms\": ${duration_ms}"
  [[ -n "${VIBEGUARD_AGENT_TYPE:-}" ]] && json="${json}, \"agent\": \"${VIBEGUARD_AGENT_TYPE}\""
  json="${json}}"

  printf '%s\n' "$json" >> "$VIBEGUARD_LOG_FILE"
  chmod 600 "$VIBEGUARD_LOG_FILE" 2>/dev/null || true

  # 同步写入全局日志（供 stats.sh 聚合分析）
  local global_log="${VIBEGUARD_LOG_DIR}/events.jsonl"
  if [[ "$VIBEGUARD_LOG_FILE" != "$global_log" ]]; then
    printf '%s\n' "$json" >> "$global_log"
    chmod 600 "$global_log" 2>/dev/null || true
  fi
}
