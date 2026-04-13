#!/usr/bin/env bash
# VibeGuard PreToolUse(Write) Hook
#
# Grading strategy:
# - Edit existing file → Release
# - New configuration/document/test file → Release
# - Create a new source code file (.rs/.py/.ts/.js/.go/.jsx/.tsx) → intercept (requires searching first and then writing)
#
#Default warn mode: remind to search first and then write (L1 constraint is covered by PostToolUse repeated detection)
# Set VIBEGUARD_WRITE_MODE=block to upgrade to hard blocking mode

set -euo pipefail

source "$(dirname "$0")/log.sh"
vg_start_timer

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | vg_json_field "tool_input.file_path")

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# W-12: Block writes to test infrastructure files (new or existing)
# Resolve symlinks first to prevent bypass via aliases (e.g. safe.txt -> conftest.py)
_REAL_PATH=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
BASENAME=$(basename "$_REAL_PATH")
# Normalise to lowercase for case-insensitive filesystem safety (e.g. default macOS HFS+)
BASENAME_LOWER=$(echo "$BASENAME" | tr '[:upper:]' '[:lower:]')
_is_test_infra=false
case "$BASENAME_LOWER" in
  conftest.py|pytest.ini|.coveragerc|setup.cfg)
    _is_test_infra=true ;;
  jest.config.*|vitest.config.*|karma.config.*|babel.config.*)
    _is_test_infra=true ;;
esac
if [[ "$_is_test_infra" == "true" ]]; then
  vg_log "pre-write-guard" "Write" "block" "Test Infrastructure File Guard (W-12)" "$FILE_PATH"
  cat <<'EOF'
{
  "decision": "block",
  "reason": "[W-12] [block] [this-edit] OBSERVATION: writing to test infrastructure file blocked (conftest.py/jest.config/pytest.ini/.coveragerc/babel.config)\nFIX: Fix the production code that is failing — do not manipulate test framework configuration"
}
EOF
  exit 0
fi

# --- [U-16] File size block: reject source files over limit before writing ---
_U16_RESULT=$(echo "$INPUT" | python3 -c '
import json, sys, os, re
from pathlib import PurePath

data = json.load(sys.stdin)
file_path = data.get("tool_input", {}).get("file_path", "")
content = data.get("tool_input", {}).get("content", "")
lines = content.count("\n") + (1 if content and not content.endswith("\n") else 0)

SOURCE_EXTS = {".rs", ".ts", ".tsx", ".js", ".jsx", ".py", ".go"}
_, ext = os.path.splitext(file_path)
is_test = any(p in file_path for p in ["/tests/", "/test/", "/__tests__/", "/spec/", "/fixtures/", "/mocks/", "/testdata/", "_test.", ".test.", ".spec.", "_test.rs", "/test_"])
if ext.lower() not in SOURCE_EXTS or is_test or lines <= 800:
    print("OK")
    sys.exit(0)

limit = 800
dir_path = os.path.dirname(os.path.abspath(file_path)) if file_path else ""
while dir_path and dir_path != "/":
    if os.path.isdir(os.path.join(dir_path, ".git")):
        claude_md = os.path.join(dir_path, "CLAUDE.md")
        if os.path.isfile(claude_md):
            try:
                with open(claude_md) as cf:
                    for cline in cf:
                        if "U-16 exempt" in cline:
                            for m in re.finditer(r"`([^`]+)`\s*\u2192\s*(\d+)", cline):
                                pattern, lim = m.group(1), int(m.group(2))
                                try:
                                    if PurePath(file_path).match(pattern):
                                        limit = max(limit, lim)
                                except (ValueError, TypeError):
                                    pass
            except (OSError, IOError):
                pass
        break
    dir_path = os.path.dirname(dir_path)

if lines > limit:
    print(f"BLOCK:{lines}:{limit}")
else:
    print("OK")
' 2>/dev/null || echo "OK")

if [[ "$_U16_RESULT" == BLOCK:* ]]; then
  _U16_LINES=$(echo "$_U16_RESULT" | cut -d: -f2)
  _U16_LIM=$(echo "$_U16_RESULT" | cut -d: -f3)
  vg_log "pre-write-guard" "Write" "block" "U-16 file size: ${_U16_LINES} > ${_U16_LIM}" "$FILE_PATH"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD [U-16] block: writing ${FILE_PATH##*/} with ${_U16_LINES} lines exceeds the ${_U16_LIM}-line limit. Split into focused submodules first. Do NOT proceed with this write."
}
BLOCK_EOF
  exit 0
fi

# File already exists (edit) → Release
if [[ -e "$FILE_PATH" ]]; then
  exit 0
fi

#Extract file name and extension
BASENAME=$(basename "$FILE_PATH")
EXT="${BASENAME##*.}"

# Release list: configuration, document, lock file, test file
case "$BASENAME" in
  *.md|*.txt|*.json|*.yaml|*.yml|*.toml|*.lock|*.css|*.html|*.svg|*.png|*.jpg)
    exit 0 ;;
  *.test.*|*.spec.*|*_test.*|*_spec.*)
    exit 0 ;;
  test_*|spec_*)
    exit 0 ;;
  .gitignore|.env*|Makefile|Dockerfile|*.sh)
    exit 0 ;;
esac

# Release: files in the test directory
case "$FILE_PATH" in
  */tests/*|*/test/*|*/__tests__/*|*/spec/*|*/fixtures/*|*/mocks/*)
    exit 0 ;;
esac

# Source code file: check whether interception is required
if ! vg_is_source_file "$FILE_PATH"; then
  exit 0
fi

# --- Source code files: reminder to search first and then write ---
# Default warn (reminder), set VIBEGUARD_WRITE_MODE=block to upgrade to hard interception
MODE="${VIBEGUARD_WRITE_MODE:-warn}"

if [[ "$MODE" == "block" ]]; then
  vg_log "pre-write-guard" "Write" "block" "New source code file not searched" "$FILE_PATH"
  cat <<'EOF'
{
  "decision": "block",
  "reason": "VIBEGUARD [L1] [block] [this-edit] OBSERVATION: new source file creation blocked — search not performed before write\nSCOPE: search required before retry — use Grep for functions/classes/structs, Glob for same-named files\nACTION: REVIEW"
}
EOF
else
  vg_log "pre-write-guard" "Write" "warn" "New source file reminder" "$FILE_PATH"
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "VIBEGUARD [L1] [review] [this-edit] OBSERVATION: new source file creation without prior search\nSCOPE: search before proceeding — use Grep for functions/classes/structs, Glob for same-named files\nACTION: REVIEW"
  }
}
EOF
fi
