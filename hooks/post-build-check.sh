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

source "$(dirname "$0")/log.sh"
vg_start_timer

INPUT=$(cat)

# Extract file_path from Edit or Write JSON
FILE_PATH=$(echo "$INPUT" | vg_json_field "tool_input.file_path")

if [[ -z "$FILE_PATH" ]]; then
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
  *) exit 0 ;;
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
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "Cargo.toml") || exit 0
    # cargo check, limit output
    ERRORS=$(cd "$PROJECT_ROOT" && cargo check --message-format=short 2>&1 | grep -E "^error" | head -10) || true
    ;;
  ts|tsx)
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "tsconfig.json") || exit 0
    # tsc type check
    ERRORS=$(cd "$PROJECT_ROOT" && npx tsc --noEmit 2>&1 | grep -E "error TS" | head -10) || true
    ;;
  js|mjs|cjs)
    # JavaScript syntax check (does not depend on tsconfig)
    command -v node >/dev/null 2>&1 || exit 0
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "package.json") || true
    ERRORS=$(node --check "$FILE_PATH" 2>&1 | head -10) || true
    ;;
  go)
    PROJECT_ROOT=$(find_project_root "$(dirname "$FILE_PATH")" "go.mod") || exit 0
    # go build check
    ERRORS=$(cd "$PROJECT_ROOT" && go build ./... 2>&1 | head -10) || true
    ;;
esac

if [[ -z "$ERRORS" ]]; then
  vg_log "post-build-check" "Edit" "pass" "" "$FILE_PATH"
  exit 0
fi

ERROR_COUNT=$(echo "$ERRORS" | wc -l | tr -d ' ')
WARNINGS="[BUILD] ${ERROR_COUNT} build errors detected after editing ${BASENAME}:
${ERRORS}"

# --- Escalation detection: continuous build failure upgrade ---
DECISION="warn"
# Fix post-build: filter by PROJECT_ROOT so failure counts are isolated per project,
# not accumulated across projects within the same session.
# Read only last 200 lines and reverse in Python to avoid loading entire file
CONSECUTIVE_FAILS=$(tail -200 "$VIBEGUARD_LOG_FILE" 2>/dev/null \
  | if [[ -n "$_VG_HELPER" ]]; then
      "$_VG_HELPER" build-fails "$VIBEGUARD_SESSION_ID" "$PROJECT_ROOT"
    else
      VG_SESSION="$VIBEGUARD_SESSION_ID" VG_PROJECT="$PROJECT_ROOT" python3 -c '
import json, sys, os
session, project = os.environ["VG_SESSION"], os.environ["VG_PROJECT"]
count, prefix = 0, project.rstrip("/") + "/"
for line in reversed(sys.stdin.read().splitlines()):
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
        if e.get("hook") != "post-build-check" or e.get("session") != session: continue
        d = e.get("detail", "")
        if project and d and not d.startswith(prefix): continue
        if e.get("decision") == "pass": break
        if e.get("decision") == "warn": count += 1
    except: continue
print(count)
'
    fi 2>/dev/null | tr -d '[:space:]' || echo "0")
CONSECUTIVE_FAILS="${CONSECUTIVE_FAILS:-0}"

if [[ "$CONSECUTIVE_FAILS" -ge 5 ]]; then
  DECISION="escalate"
  WARNINGS="[U-25 ESCALATE] Continuous ${CONSECUTIVE_FAILS} build failures! You must fix the build errors before continuing editing. Recommendation: Run the complete build command to view all errors and locate the root cause and fix them at once. ${WARNINGS}"
fi

vg_log "post-build-check" "Edit" "$DECISION" "Build errors ${ERROR_COUNT}" "$FILE_PATH"

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
