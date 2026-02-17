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

vg_log() {
  local hook="$1"
  local tool="$2"
  local decision="$3"
  local reason="${4:-}"
  local detail="${5:-}"

  mkdir -p "$VIBEGUARD_LOG_DIR"

  python3 -c "
import json, datetime
event = {
    'ts': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'hook': '$hook',
    'tool': '$tool',
    'decision': '$decision',
    'reason': '''$reason'''.strip(),
    'detail': '''$detail'''.strip()[:200]
}
with open('$VIBEGUARD_LOG_FILE', 'a') as f:
    f.write(json.dumps(event, ensure_ascii=False) + '\n')
" 2>/dev/null || true
}
