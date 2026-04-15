#!/usr/bin/env bash
# VibeGuard PostToolUse(Write) Hook
#
# After the new source code file is created, detect whether there are duplicate implementations in the project:
# 1. Files with the same name (source code files with the same name appear in different directories)
# 2. Duplication of key definitions (struct/class/interface/func already exists in other files)
#
# After-the-fact review, the operation will not be blocked and only a warning will be output.
# Cooperate with pre-write-guard (warn mode): pre-reminder + post-review.

set -euo pipefail

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/_lib/stub_detect.sh"
vg_start_timer

INPUT=$(cat)

RESULT=$(echo "$INPUT" | vg_json_two_fields "tool_input.file_path" "tool_input.content")

FILE_PATH=$(echo "$RESULT" | head -1)
CONTENT=$(echo "$RESULT" | tail -n +2)

if [[ -z "$FILE_PATH" ]] || [[ -z "$CONTENT" ]]; then
  exit 0
fi

#Extract file name and extension
BASENAME=$(basename "$FILE_PATH")
EXT="${BASENAME##*.}"

# Only check source files
if ! vg_is_source_file "$FILE_PATH"; then
  vg_log "post-write-guard" "Write" "pass" "Non-source file" "$FILE_PATH"
  exit 0
fi

# Find the project root directory (look up for .git)
PROJECT_DIR="$FILE_PATH"
while [[ "$PROJECT_DIR" != "/" ]]; do
  PROJECT_DIR=$(dirname "$PROJECT_DIR")
  if [[ -d "$PROJECT_DIR/.git" ]]; then
    break
  fi
done

if [[ "$PROJECT_DIR" == "/" ]]; then
  vg_log "post-write-guard" "Write" "pass" "No git project" "$FILE_PATH"
  exit 0
fi

WARNINGS=""

#Scan budget: avoid triggering a high-cost full scan for every write in a large warehouse
MAX_SCAN_FILES="${VG_SCAN_MAX_FILES:-5000}"
MAX_SCAN_DEFS="${VG_SCAN_MAX_DEFS:-20}"
MAX_MATCHES="${VG_SCAN_MATCH_LIMIT:-5}"
HAS_RG=0
if command -v rg >/dev/null 2>&1; then
  HAS_RG=1
fi

RG_EXCLUDES=(
  --glob '!**/node_modules/**'
  --glob '!**/.git/**'
  --glob '!**/target/**'
  --glob '!**/vendor/**'
  --glob '!**/dist/**'
  --glob '!**/build/**'
  --glob '!**/__pycache__/**'
  --glob '!**/.venv/**'
  # Fix post-write: exclude tests directories from same-name search
  --glob '!**/tests/**'
  --glob '!**/__tests__/**'
  --glob '!**/test/**'
  --glob '!**/spec/**'
)

SCAN_DEGRADED=0
FILE_COUNT=0
if [[ "${HAS_RG}" -eq 1 ]]; then
  FILE_COUNT=$(rg --files "${RG_EXCLUDES[@]}" "$PROJECT_DIR" 2>/dev/null | wc -l | tr -d ' ')
else
  FILE_COUNT=$(find "$PROJECT_DIR" \
    -type f \
    -not -path "*/node_modules/*" \
    -not -path "*/.git/*" \
    -not -path "*/target/*" \
    -not -path "*/vendor/*" \
    -not -path "*/dist/*" \
    -not -path "*/build/*" \
    -not -path "*/__pycache__/*" \
    -not -path "*/.venv/*" \
    2>/dev/null | wc -l | tr -d ' ')
fi

if [[ "${FILE_COUNT}" -gt "${MAX_SCAN_FILES}" ]]; then
  SCAN_DEGRADED=1
fi

# --- Check 1: File with the same name ---
# Search for files with the same name in the project (exclude node_modules, .git, target, vendor, etc.)
if [[ "${HAS_RG}" -eq 1 ]]; then
  SAME_NAME_FILES=$(rg --files "${RG_EXCLUDES[@]}" -g "**/${BASENAME}" "$PROJECT_DIR" 2>/dev/null \
    | grep -Fvx -- "$FILE_PATH" \
    | head -"${MAX_MATCHES}" || true)
else
  SAME_NAME_FILES=$(find "$PROJECT_DIR" \
    -name "$BASENAME" \
    -not -path "$FILE_PATH" \
    -not -path "*/node_modules/*" \
    -not -path "*/.git/*" \
    -not -path "*/target/*" \
    -not -path "*/vendor/*" \
    -not -path "*/dist/*" \
    -not -path "*/build/*" \
    -not -path "*/__pycache__/*" \
    -not -path "*/.venv/*" \
    -not -path "*/tests/*" \
    -not -path "*/__tests__/*" \
    -not -path "*/test/*" \
    -not -path "*/spec/*" \
    2>/dev/null | head -"${MAX_MATCHES}" || true)
fi

if [[ -n "$SAME_NAME_FILES" ]]; then
  FILE_LIST=$(echo "$SAME_NAME_FILES" | tr '\n' ', ' | sed 's/,$//')
  WARNINGS="[L1] [review] [this-edit] OBSERVATION: duplicate filename found in project: ${FILE_LIST}
SCOPE: REVIEW-ONLY — do not delete existing files or auto-merge; confirm intent before acting
ACTION: REVIEW"
fi

if [[ "${SCAN_DEGRADED}" -eq 1 ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS}
---
}[L1] [info] [this-edit] OBSERVATION: project has ${FILE_COUNT} files, exceeding ${MAX_SCAN_FILES} threshold — deep duplicate scan skipped
SCOPE: informational only — no action required
ACTION: SKIP"
fi

# --- Check 2: Duplicate key definition ---
#Extract key definition names from the new file contents
DEFINITIONS=$(echo "$CONTENT" | EXT="$EXT" python3 -c "
import sys, re, os

content = sys.stdin.read()
ext = os.environ.get('EXT', '')
names = set()

# Fix post-write: use language-specific patterns to avoid cross-language pollution.
# Each language only extracts definitions that are syntactically meaningful for it.
if ext == 'rs':
    patterns = [
        r'(?:pub\s+(?:\w+\s+)?)?(?:struct|enum|trait|union)\s+(\w+)',
        r'(?:pub\s+(?:\w+\s+)?)?fn\s+(\w+)',
    ]
elif ext in ('ts', 'tsx', 'js', 'jsx'):
    patterns = [
        r'(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+(\w+)',
        r'(?:export\s+)?interface\s+(\w+)',
        r'(?:export\s+)?(?:async\s+)?function\s+(\w+)',
        r'(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s+)?\(',
    ]
elif ext == 'py':
    patterns = [
        r'class\s+(\w+)',
        r'def\s+(\w+)\s*\(',
    ]
elif ext == 'go':
    patterns = [
        r'type\s+(\w+)\s+(?:struct|interface)',
        r'func\s+(?:\([^)]+\)\s+)?(\w+)\s*\(',
    ]
else:
    # Minimal fallback for other languages
    patterns = [
        r'(?:class|interface)\s+(\w+)',
        r'(?:function|func|def)\s+(\w+)',
    ]

for p in patterns:
    for m in re.finditer(p, content):
        name = m.group(1)
        if name.startswith('_'):
            continue
        if len(name) > 3 and name not in ('self', 'init', 'main', 'test', 'None', 'True', 'False', 'this', 'super', 'impl', 'type', 'move', 'async'):
            names.add(name)

for name in sorted(names):
    print(name)
" 2>/dev/null || true)

if [[ -n "$DEFINITIONS" ]] && [[ "${SCAN_DEGRADED}" -eq 0 ]]; then
  DEFINITIONS=$(echo "$DEFINITIONS" | head -n "${MAX_SCAN_DEFS}")
  DUPLICATE_DEFS=""
  while IFS= read -r defname; do
    # Search for this definition name in the project (excluding the new file itself)
    if [[ "${HAS_RG}" -eq 1 ]]; then
      FOUND=$(rg -l "${RG_EXCLUDES[@]}" -g "**/*.${EXT}" \
        -e "struct[[:space:]]+${defname}\\b" \
        -e "class[[:space:]]+${defname}\\b" \
        -e "interface[[:space:]]+${defname}\\b" \
        -e "type[[:space:]]+${defname}\\b" \
        -e "fn[[:space:]]+${defname}\\b" \
        -e "func[[:space:]]+${defname}\\b" \
        -e "def[[:space:]]+${defname}\\b" \
        -e "function[[:space:]]+${defname}\\b" \
        "$PROJECT_DIR" 2>/dev/null \
        | grep -Fvx -- "$FILE_PATH" \
        | head -3 || true)
    else
      FOUND=$(grep -rl --include="*.${EXT}" \
        -e "struct ${defname}" \
        -e "class ${defname}" \
        -e "interface ${defname}" \
        -e "type ${defname}" \
        -e "fn ${defname}" \
        -e "func ${defname}" \
        -e "def ${defname}" \
        -e "function ${defname}" \
        "$PROJECT_DIR" 2>/dev/null \
        | grep -Fv -- "$FILE_PATH" \
        | grep -v node_modules \
        | grep -v ".git/" \
        | grep -v "/target/" \
        | grep -v "/vendor/" \
        | grep -v "/dist/" \
        | head -3 || true)
    fi

    if [[ -n "$FOUND" ]]; then
      FOUND_LIST=$(echo "$FOUND" | tr '\n' ', ' | sed 's/,$//')
      DUPLICATE_DEFS="${DUPLICATE_DEFS:+${DUPLICATE_DEFS} }${defname}(in ${FOUND_LIST})"
    fi
  done <<< "$DEFINITIONS"

  if [[ -n "$DUPLICATE_DEFS" ]]; then
    WARNINGS="${WARNINGS:+${WARNINGS}
---
}[L1] [review] [this-edit] OBSERVATION: duplicate definition(s) found in project: ${DUPLICATE_DEFS}
FIX: Reuse the existing definition instead of creating a new one
DO NOT: Delete existing definitions or merge code without confirming intent"
  fi
fi

# --- Anti-Stub detection (GSD reference: Level 2 product verification Level 2 — Substantiveness) ---
STUB_WARNINGS=$(vg_detect_stubs "$FILE_PATH" "$CONTENT")
if [[ -n "$STUB_WARNINGS" ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS}
---
}${STUB_WARNINGS}"
fi

# --- [U-16] File size guard: 800-line default limit with project exemptions ---
case "$FILE_PATH" in
  *.rs|*.ts|*.tsx|*.js|*.jsx|*.py|*.go)
    case "$FILE_PATH" in
      */tests/*|*_test.*|*.test.*|*.spec.*|*_test.rs|*/test_*) ;;
      *)
        _U16_TOTAL=$(echo "$CONTENT" | wc -l | tr -d ' ')
        if [[ "$_U16_TOTAL" -gt 800 ]]; then
          _U16_LIMIT=800
          if [[ "$PROJECT_DIR" != "/" && -f "$PROJECT_DIR/CLAUDE.md" ]]; then
            _U16_EXEMPT=$(VG_CLAUDE_MD="$PROJECT_DIR/CLAUDE.md" VG_FILE_PATH="$FILE_PATH" python3 -c '
import os, re
from pathlib import PurePath
claude_md = os.environ["VG_CLAUDE_MD"]
file_path = os.environ["VG_FILE_PATH"]
limit = 0
try:
    with open(claude_md) as f:
        for line in f:
            if "U-16 exempt" not in line:
                continue
            for pair in re.finditer(r"`([^`]+)`\s*→\s*(\d+)", line):
                pattern, lim = pair.group(1), int(pair.group(2))
                try:
                    if PurePath(file_path).match(pattern):
                        limit = max(limit, lim)
                except (ValueError, TypeError):
                    continue
except FileNotFoundError:
    pass
print(limit)
' 2>/dev/null | tr -d '[:space:]' || echo "0")
            _U16_EXEMPT="${_U16_EXEMPT:-0}"
            if [[ "$_U16_EXEMPT" -gt 0 ]]; then
              _U16_LIMIT="$_U16_EXEMPT"
            fi
          fi
          if [[ "$_U16_TOTAL" -gt "$_U16_LIMIT" ]]; then
            WARNINGS="${WARNINGS:+${WARNINGS}
---
}[U-16] [review] [this-file] OBSERVATION: file has ${_U16_TOTAL} lines, exceeding ${_U16_LIMIT}-line limit
FIX: Split into focused submodules by responsibility; plan as a separate task
DO NOT: Start splitting now — finish the current task first, then refactor"
          fi
        fi
        ;;
    esac
    ;;
esac

if [[ -z "$WARNINGS" ]]; then
  vg_log "post-write-guard" "Write" "pass" "" "$FILE_PATH"
  exit 0
fi

vg_log "post-write-guard" "Write" "warn" "$WARNINGS" "$FILE_PATH"

VG_WARNINGS="$WARNINGS" python3 -c '
import json, os
warnings = os.environ.get("VG_WARNINGS", "")
result = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "VIBEGUARD duplicate detection:" + warnings
    }
}
print(json.dumps(result, ensure_ascii=False))
'
