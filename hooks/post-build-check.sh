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
    post_build_filter_or_head "${pattern}" "${output}"
  fi
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
    ERRORS=$(post_build_run "$PROJECT_ROOT" "cargo check --message-format=short" "^error" cargo check --message-format=short)
    ;;
  ts|tsx)
    if ! PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "tsconfig.json"); then
      post_build_log_skip "missing tsconfig.json" "${FILE_PATH}"
      exit 0
    fi
    ERRORS=$(post_build_run "$PROJECT_ROOT" "npx tsc --noEmit" "error TS" npx tsc --noEmit)
    ;;
  js|mjs|cjs)
    # JavaScript syntax check (does not depend on tsconfig)
    if ! command -v node >/dev/null 2>&1; then
      post_build_log_skip "missing node" "${FILE_PATH}"
      exit 0
    fi
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "package.json") || true
    ERRORS=$(post_build_run "" "node --check" "." node --check "$FILE_PATH")
    ;;
  go)
    if ! PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "go.mod"); then
      post_build_log_skip "missing go.mod" "${FILE_PATH}"
      exit 0
    fi
    ERRORS=$(post_build_run "$PROJECT_ROOT" "go build ./..." "." go build ./...)
    ;;
esac

if [[ -z "$ERRORS" ]]; then
  vg_log "post-build-check" "PostToolUse" "pass" "" "$FILE_PATH"
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

VG_WARNINGS="$WARNINGS" VG_DECISION="$DECISION" python3 -c '
import json, os
warnings = os.environ.get("VG_WARNINGS", "")
decision = os.environ.get("VG_DECISION", "warn")
prefix = "VIBEGUARD build upgrade warning" if decision == "escalate" else "VIBEGUARD build check"
result = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": prefix + "：" + warnings
    }
}
print(json.dumps(result, ensure_ascii=False))
'
