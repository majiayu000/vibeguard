#!/usr/bin/env bash
# VibeGuard PostToolUse(Edit|Write) Hook — Automatic build check after editing
#
# Automatically run the build check of the corresponding language after editing the source code file:
#   - Rust (.rs): cargo check
#   - TypeScript (.ts/.tsx): npx tsc --noEmit
#   - JavaScript (.js/.mjs/.cjs): node --check
#   - Go (.go): go build ./...
#
# Only output warnings, do not prevent operations.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${HOOK_DIR}/log.sh"
source "${HOOK_DIR}/_lib/timeout.sh"
vg_start_timer
VG_EVENT_LOG_LIB="${VG_EVENT_LOG_LIB:-${HOOK_DIR}/_lib}"
POST_BUILD_TIMEOUT="${VIBEGUARD_POST_BUILD_TIMEOUT:-30}"
POST_BUILD_CACHE_TTL="${VIBEGUARD_POST_BUILD_CACHE_TTL:-10}"
POST_BUILD_CACHE_VERSION="v1"
POST_BUILD_CACHE_HIT=0

INPUT=$(cat)

post_build_log_skip() {
  local reason="$1" file_path="${2:-}"
  vg_log "post-build-check" "PostToolUse" "pass" "skip: ${reason}" "${file_path}"
}

post_build_filter_or_head() {
  local pattern="$1" output="$2" filtered
  filtered=$(printf '%s\n' "${output}" | grep -E "${pattern}" | head -10 || true)
  if [[ -n "${filtered}" ]]; then
    printf '%s\n' "${filtered}"
  else
    printf '%s\n' "${output}" | head -10
  fi
}

post_build_hash_stream() {
  shasum -a 256 | awk '{print $1}'
}

post_build_hash_file() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

post_build_cache_enabled() {
  [[ "$POST_BUILD_CACHE_TTL" =~ ^[0-9]+$ && "$POST_BUILD_CACHE_TTL" -gt 0 ]]
}

post_build_cache_root() {
  local cache_root="${VIBEGUARD_PROJECT_LOG_DIR:-${VIBEGUARD_LOG_DIR}/projects/post-build-check}/cache/post-build-check"
  mkdir -p "$cache_root" 2>/dev/null || return 1
  printf '%s\n' "$cache_root"
}

post_build_worktree_state() {
  local project_root="$1" file_path="$2"
  local state_root="${project_root:-$(dirname "$file_path")}"

  if [[ -n "$state_root" && -d "$state_root" ]] && git -C "$state_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    {
      printf 'git\n'
      git -C "$state_root" rev-parse HEAD 2>/dev/null || true
      git -C "$state_root" status --porcelain=v1 --untracked-files=all -- . 2>/dev/null || true
      git -C "$state_root" diff --no-ext-diff --binary -- . 2>/dev/null || true
      git -C "$state_root" diff --cached --no-ext-diff --binary -- . 2>/dev/null || true
      (cd "$state_root" && git ls-files --others --exclude-standard -z -- . 2>/dev/null | xargs -0 shasum -a 256 2>/dev/null || true)
    } | post_build_hash_stream
    return 0
  fi

  {
    printf 'file\n'
    printf '%s\n' "$file_path"
    [[ -f "$file_path" ]] && post_build_hash_file "$file_path"
  } | post_build_hash_stream
}

post_build_cache_key() {
  local project_root="$1" ext="$2" label="$3" state="$4"
  printf '%s\0%s\0%s\0%s\0%s' "$POST_BUILD_CACHE_VERSION" "$project_root" "$ext" "$label" "$state" | post_build_hash_stream
}

post_build_cache_read() {
  local cache_file="$1" now ts
  [[ -f "$cache_file" ]] || return 1
  IFS= read -r ts < "$cache_file" || return 1
  [[ "$ts" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  [[ $((now - ts)) -le "$POST_BUILD_CACHE_TTL" ]] || return 1
  POST_BUILD_CACHE_HIT=1
  tail -n +3 "$cache_file" 2>/dev/null || true
  return 0
}

post_build_cache_write() {
  local cache_file="$1" errors="$2" tmp_file
  tmp_file="${cache_file}.$$"
  {
    date +%s
    printf '%s\n' "$POST_BUILD_CACHE_VERSION"
    printf '%s\n' "$errors"
  } > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$cache_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null || true
}

post_build_run() {
  local project_root="$1" label="$2" pattern="$3"
  shift 3
  local output status
  status=0
  if [[ -n "${project_root}" ]]; then
    output=$(cd "${project_root}" && vg_run_with_timeout "${POST_BUILD_TIMEOUT}" "$@" 2>&1) || status=$?
  else
    output=$(vg_run_with_timeout "${POST_BUILD_TIMEOUT}" "$@" 2>&1) || status=$?
  fi

  if [[ ${status} -eq 124 ]]; then
    printf '%s\n' "post-build-check timeout after ${POST_BUILD_TIMEOUT}s while running: ${label}"
  elif [[ ${status} -ne 0 ]]; then
    if [[ -n "${output}" ]]; then
      post_build_filter_or_head "${pattern}" "${output}"
    else
      printf '%s\n' "post-build-check failed with exit status ${status} while running: ${label}"
    fi
  fi
}

post_build_run_cached() {
  local project_root="$1" ext="$2" label="$3" pattern="$4"
  shift 4
  local cache_dir cache_file cache_key errors state

  if post_build_cache_enabled \
    && cache_dir=$(post_build_cache_root) \
    && state=$(post_build_worktree_state "$project_root" "$FILE_PATH"); then
    cache_key=$(post_build_cache_key "${project_root:-$(dirname "$FILE_PATH")}" "$ext" "$label" "$state")
    cache_file="${cache_dir}/${cache_key}.txt"
    if post_build_cache_read "$cache_file"; then
      return 0
    fi
  fi

  errors=$(post_build_run "$project_root" "$label" "$pattern" "$@")
  if [[ -n "${cache_file:-}" ]]; then
    post_build_cache_write "$cache_file" "$errors"
  fi
  printf '%s\n' "$errors"
}

# Extract file_path from Edit or Write JSON
FILE_PATH=$(echo "$INPUT" | vg_json_field "tool_input.file_path")

if [[ -z "$FILE_PATH" ]]; then
  post_build_log_skip "missing file_path" ""
  exit 0
fi

# Normalize to absolute path so project-isolation filter in escalation detection
# works correctly regardless of whether Claude passes relative or absolute paths.
if [[ "$FILE_PATH" != /* ]]; then
  FILE_PATH="$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd)/$(basename "$FILE_PATH")" \
    || FILE_PATH="$(pwd)/$FILE_PATH"
fi

# Get file extension
BASENAME=$(basename "$FILE_PATH")
EXT="${BASENAME##*.}"

# Only handle languages that require build checks
case "$EXT" in
  rs|ts|tsx|go|js|mjs|cjs) ;;
  *)
    post_build_log_skip "unsupported extension .${EXT}" "${FILE_PATH}"
    exit 0
    ;;
esac

# Search upwards in the project root directory (find different markup files based on language)
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
PROJECT_ROOT=""

case "$EXT" in
  rs)
    if ! PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "Cargo.toml"); then
      post_build_log_skip "missing Cargo.toml" "${FILE_PATH}"
      exit 0
    fi
    ERRORS=$(post_build_run_cached "$PROJECT_ROOT" "$EXT" "cargo check --message-format=short" "^error" cargo check --message-format=short)
    ;;
  ts|tsx)
    if ! PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "tsconfig.json"); then
      post_build_log_skip "missing tsconfig.json" "${FILE_PATH}"
      exit 0
    fi
    ERRORS=$(post_build_run_cached "$PROJECT_ROOT" "$EXT" "npx tsc --noEmit" "error TS" npx tsc --noEmit)
    ;;
  js|mjs|cjs)
    # JavaScript syntax check (does not depend on tsconfig)
    if ! command -v node >/dev/null 2>&1; then
      post_build_log_skip "missing node" "${FILE_PATH}"
      exit 0
    fi
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "package.json") || true
    ERRORS=$(post_build_run_cached "$PROJECT_ROOT" "$EXT" "node --check" "." node --check "$FILE_PATH")
    ;;
  go)
    if ! PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "go.mod"); then
      post_build_log_skip "missing go.mod" "${FILE_PATH}"
      exit 0
    fi
    ERRORS=$(post_build_run_cached "$PROJECT_ROOT" "$EXT" "go build ./..." "." go build ./...)
    ;;
esac

if [[ -z "$ERRORS" ]]; then
  if [[ "$POST_BUILD_CACHE_HIT" -eq 1 ]]; then
    vg_log "post-build-check" "PostToolUse" "pass" "cache hit" "$FILE_PATH"
  else
    vg_log "post-build-check" "PostToolUse" "pass" "" "$FILE_PATH"
  fi
  exit 0
fi

ERROR_COUNT=$(echo "$ERRORS" | wc -l | tr -d ' ')
WARNINGS="[BUILD] ${ERROR_COUNT} build errors detected after editing ${BASENAME}:
${ERRORS}"

# --- Escalation detection: continuous build failure upgrade ---
DECISION="warn"
# Fix post-build: filter by PROJECT_ROOT so failure counts are isolated per project,
# not accumulated across projects within the same session.
# Read only last 200 lines to avoid loading entire file.
CONSECUTIVE_FAILS=$(tail -200 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
  | "$_VIBEGUARD_RUNTIME" build-fails "$VIBEGUARD_SESSION_ID" "$PROJECT_ROOT" \
  2>/dev/null | tr -d '[:space:]' || echo "0")
CONSECUTIVE_FAILS="${CONSECUTIVE_FAILS:-0}"

if [[ "$CONSECUTIVE_FAILS" -ge 5 ]]; then
  DECISION="escalate"
  WARNINGS="[U-25 ESCALATE] Continuous ${CONSECUTIVE_FAILS} build failures! You must fix the build errors before continuing editing. Recommendation: Run the complete build command to view all errors and locate the root cause and fix them at once. ${WARNINGS}"
fi

if [[ "${ERRORS}" == post-build-check\ timeout* ]]; then
  vg_log "post-build-check" "PostToolUse" "warn" "${ERRORS}" "$FILE_PATH"
else
  vg_log "post-build-check" "PostToolUse" "$DECISION" "Build errors ${ERROR_COUNT}" "$FILE_PATH"
fi

if [[ "$DECISION" == "escalate" ]]; then
  printf 'VIBEGUARD build upgrade warning：%s' "$WARNINGS" | "$_VIBEGUARD_RUNTIME" hook-context PostToolUse
else
  printf 'VIBEGUARD build check：%s' "$WARNINGS" | "$_VIBEGUARD_RUNTIME" hook-context PostToolUse
fi
