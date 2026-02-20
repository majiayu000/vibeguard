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

  VG_HOOK="$hook" VG_TOOL="$tool" VG_DECISION="$decision" \
  VG_REASON="$reason" VG_DETAIL="$detail" VG_LOG_FILE="$VIBEGUARD_LOG_FILE" \
  python3 -c '
import json, datetime, os
event = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "hook": os.environ.get("VG_HOOK", ""),
    "tool": os.environ.get("VG_TOOL", ""),
    "decision": os.environ.get("VG_DECISION", ""),
    "reason": os.environ.get("VG_REASON", "").strip(),
    "detail": os.environ.get("VG_DETAIL", "").strip()[:200],
}
with open(os.environ["VG_LOG_FILE"], "a") as f:
    f.write(json.dumps(event, ensure_ascii=False) + "\n")
' 2>/dev/null || true
}
