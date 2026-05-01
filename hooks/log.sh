#!/usr/bin/env bash
# VibeGuard Hook log module
#
# All hook scripts source this file and use vg_log to record events to a JSONL file.
# Log path: ~/.vibeguard/events.jsonl
#
# Usage:
#   source "$(dirname "$0")/log.sh"
#   vg_log "pre-bash-guard" "Bash" "block" "force push" "git push --force"
#   vg_log "post-edit-guard" "Edit" "warn" "unwrap detected" "src/main.rs"
#   vg_log "pre-write-guard" "Write" "pass" "" "src/lib.rs"
#
#Supported decision types:
# pass — pass the inspection and release
# warn — Problem detected, warns but does not prevent
# block — serious problem, blocking operation
# gate - access control trigger, user confirmation is required
# escalate — Escalation warning, the same issue will automatically escalate after multiple warns
# complete — Operation completion confirmation

VIBEGUARD_LOG_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"

#Isolate logs by project: use the hash of the git repo root directory path to distinguish different projects
_vg_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "global")
_vg_project_hash=$(printf '%s' "$_vg_repo_root" | shasum -a 256 2>/dev/null | cut -c1-8) || _vg_project_hash="fallback0"
VIBEGUARD_PROJECT_LOG_DIR="${VIBEGUARD_LOG_DIR}/projects/${_vg_project_hash}"
mkdir -p "$VIBEGUARD_PROJECT_LOG_DIR" 2>/dev/null
VIBEGUARD_LOG_FILE="${VIBEGUARD_PROJECT_LOG_DIR}/events.jsonl"

# Record hash → project path mapping (for use in the GC learning phase)
if [[ "$_vg_repo_root" != "global" ]]; then
  printf '%s' "$_vg_repo_root" > "$VIBEGUARD_PROJECT_LOG_DIR/.project-root" 2>/dev/null || true
fi

# Source file extension list (shared constant)
VG_SOURCE_EXTS="rs py ts js mjs cjs tsx jsx go java kt swift rb"

# Determine whether the file is a source code file
# Usage: vg_is_source_file "path/to/file.rs" && echo "is source code"
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

# Resolve vg-helper binary path (Rust, ~4ms) with Python fallback (~55ms)
_VG_HELPER=""
for _candidate in \
  "${HOME}/.vibeguard/installed/bin/vg-helper" \
  "$(dirname "$0")/../vg-helper/target/release/vg-helper" \
  "$(dirname "$0")/vg-helper"; do
  if [[ -f "$_candidate" ]] && [[ -x "$_candidate" ]]; then
    _VG_HELPER="$_candidate"
    break
  fi
done
_VG_HELPER_JSON_FIELD_STRICT=0
if [[ -n "$_VG_HELPER" ]]; then
  if [[ "$(printf '{"__vg_probe":"ok"}' | "$_VG_HELPER" json-field --strict __vg_probe 2>/dev/null || true)" == "ok" ]]; then
    _VG_HELPER_JSON_FIELD_STRICT=1
  fi
fi


_VG_LOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/_lib" && pwd)"
source "${_VG_LOG_LIB_DIR}/log_json.sh"
source "${_VG_LOG_LIB_DIR}/log_session.sh"
source "${_VG_LOG_LIB_DIR}/log_timer.sh"
source "${_VG_LOG_LIB_DIR}/log_redact.sh"
source "${_VG_LOG_LIB_DIR}/log_write.sh"
