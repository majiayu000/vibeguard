#!/usr/bin/env bash
# Shared wrapper preflight for per-hook runtime environment.

_vg_runtime_env_hash() {
  local value="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 2>/dev/null | cut -c1-8
  elif command -v cksum >/dev/null 2>&1; then
    printf '%s' "$value" | cksum | awk '{print $1}'
  else
    return 1
  fi
}

_vg_runtime_env_write_session_file() {
  local dest="$1" start="$2" session="$3" tmp
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  tmp=$(mktemp "${VIBEGUARD_PROJECT_LOG_DIR}/.session_tmp_XXXXXX" 2>/dev/null) \
    || tmp="${dest}.tmp.$$"
  printf '%s\n%s\n' "$start" "$session" > "$tmp" \
    && mv "$tmp" "$dest" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; printf '%s\n%s\n' "$start" "$session" > "$dest"; }
}

_vg_prepare_hook_runtime_env() {
  export PYTHONUTF8=1
  export PYTHONIOENCODING=utf-8

  VIBEGUARD_LOG_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
  export VIBEGUARD_LOG_DIR

  local repo_root project_hash
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "global")
  project_hash="${VIBEGUARD_PROJECT_HASH:-$(_vg_runtime_env_hash "$repo_root" 2>/dev/null || printf '%s' "fallback0")}"

  if [[ -z "${VIBEGUARD_PROJECT_LOG_DIR:-}" || -z "${VIBEGUARD_LOG_FILE:-}" ]]; then
    VIBEGUARD_PROJECT_HASH="$project_hash"
    VIBEGUARD_PROJECT_LOG_DIR="${VIBEGUARD_LOG_DIR}/projects/${project_hash}"
    VIBEGUARD_LOG_FILE="${VIBEGUARD_PROJECT_LOG_DIR}/events.jsonl"
    mkdir -p "$VIBEGUARD_PROJECT_LOG_DIR" 2>/dev/null || true
    if [[ "$repo_root" != "global" ]]; then
      printf '%s' "$repo_root" > "${VIBEGUARD_PROJECT_LOG_DIR}/.project-root" 2>/dev/null || true
    fi
  fi
  export VIBEGUARD_PROJECT_HASH VIBEGUARD_PROJECT_LOG_DIR VIBEGUARD_LOG_FILE

  VIBEGUARD_CLI="${VIBEGUARD_CLI:-unknown}"
  if [[ -z "${VIBEGUARD_SESSION_ID:-}" ]]; then
    local parent_pid proc_start session_file stored_start reuse
    parent_pid="${VIBEGUARD_PARENT_PID:-$PPID}"
    proc_start=$(TZ=UTC ps -o lstart= -p "$parent_pid" 2>/dev/null | xargs || printf '%s' "unknown")
    session_file="${VIBEGUARD_PROJECT_LOG_DIR}/.session_${VIBEGUARD_CLI}_${parent_pid}"
    reuse=false
    if [[ -f "$session_file" ]] && [[ -n "$(find "$session_file" -mmin -30 2>/dev/null)" ]]; then
      stored_start=$(head -1 "$session_file" 2>/dev/null || true)
      if [[ "$stored_start" == "$proc_start" ]]; then
        reuse=true
      fi
    fi
    if [[ "$reuse" == "true" ]]; then
      VIBEGUARD_SESSION_ID=$(tail -1 "$session_file" 2>/dev/null || true)
      touch "$session_file" 2>/dev/null || true
    fi
    if [[ -z "${VIBEGUARD_SESSION_ID:-}" ]]; then
      VIBEGUARD_SESSION_ID=$(printf '%04x%04x' $RANDOM $RANDOM)
      _vg_runtime_env_write_session_file "$session_file" "$proc_start" "$VIBEGUARD_SESSION_ID"
    fi
    find "${VIBEGUARD_PROJECT_LOG_DIR}" -maxdepth 1 -name ".session_*" -mmin +120 -delete 2>/dev/null || true
  fi
  export VIBEGUARD_CLI VIBEGUARD_SESSION_ID
}
