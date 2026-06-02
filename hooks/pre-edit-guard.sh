#!/usr/bin/env bash
# VibeGuard PreToolUse(Edit) Hook
#
# Anti-hallucination check before editing files:
# - Detect whether the edited file exists (prevents AI from editing non-existent file paths)
# - Check if old_string is actually in the file (to prevent AI hallucinating editing content)

set -euo pipefail

source "$(dirname "$0")/log.sh"

INPUT=$(cat)

# Base U-16 limit resolved from env var > ~/.vibeguard/config.json > built-in 800.
_U16_BASE_LIMIT=$(vg_config_get_int VG_U16_LIMIT u16.limit 800)
_U16_WARN_LIMIT=$(vg_u16_warn_limit "$_U16_BASE_LIMIT")
if [[ -n "${_VIBEGUARD_RUNTIME:-}" ]]; then
  _VG_FAST_RESULT=$(printf '%s' "$INPUT" \
    | "$_VIBEGUARD_RUNTIME" pre-edit-check "$_U16_BASE_LIMIT" "$_U16_WARN_LIMIT" "$VIBEGUARD_LOG_FILE" \
    2>/dev/null || true)
  _VG_FAST_STATUS="${_VG_FAST_RESULT%%$'\n'*}"
  case "$_VG_FAST_STATUS" in
    SKIP)
      exit 0
      ;;
    FAST_LOGGED)
      exit 0
      ;;
    FAST_OUTPUT)
      _VG_FAST_PAYLOAD="${_VG_FAST_RESULT#*$'\n'}"
      [[ "$_VG_FAST_PAYLOAD" != "$_VG_FAST_RESULT" ]] && printf '%s\n' "$_VG_FAST_PAYLOAD"
      exit 0
      ;;
  esac
fi

vg_start_timer

# Complete all checks directly in Python to avoid bash variable passing from destroying old_string
# (<<<heredoc appends \n, $() swallows trailing newlines, echo escapes special characters)
CHECK_RESULT=$(VG_U16_BASE_LIMIT="$_U16_BASE_LIMIT" VG_U16_WARN_LIMIT="$_U16_WARN_LIMIT" python3 -c '
import json, sys, os, re
from pathlib import PurePath

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print("ERROR")
    print("")
    print("MALFORMED_JSON")
    sys.exit(0)

def get_nested(d, path):
    val = d
    for k in path.split("."):
        if isinstance(val, dict):
            val = val.get(k, "")
        else:
            return ""
    return val if isinstance(val, str) else ""

file_path = get_nested(data, "tool_input.file_path")
old_string = get_nested(data, "tool_input.old_string")
new_string = get_nested(data, "tool_input.new_string")
tool_input = data.get("tool_input", {}) if isinstance(data.get("tool_input"), dict) else {}
replace_all = bool(tool_input.get("replace_all", False))
patch_line_delta = tool_input.get("vibeguard_line_delta")

if not file_path:
    print("PASS")
    print("")
    sys.exit(0)

print("CHECK")
print(file_path)

# W-12: Block edits to test infrastructure files
real_path = os.path.realpath(file_path)
basename = os.path.basename(real_path).lower()
PROTECTED_EXACT = {"conftest.py", "pytest.ini", ".coveragerc", "setup.cfg"}
PROTECTED_PATTERNS = [
    r"^jest\.config\.",
    r"^vitest\.config\.",
    r"^karma\.config\.",
    r"^babel\.config\.",
]
is_protected = basename in PROTECTED_EXACT or any(re.match(p, basename) for p in PROTECTED_PATTERNS)
if is_protected:
    print("TEST_INFRA_PROTECTED")
    sys.exit(0)

if not os.path.isfile(file_path):
    print("FILE_NOT_FOUND")
    sys.exit(0)

with open(file_path, "r", errors="replace") as f:
    content = f.read()

if old_string and old_string not in content:
    print("OLD_STRING_NOT_FOUND")
    sys.exit(0)

# U-16: Estimate file size after edit and block if over limit
SOURCE_EXTS = {".rs", ".ts", ".tsx", ".js", ".jsx", ".py", ".go"}
_, ext = os.path.splitext(file_path)
is_test = any(p in file_path for p in ["/tests/", "/test/", "/__tests__/", "/spec/", "/fixtures/", "/mocks/", "/testdata/", "_test.", ".test.", ".spec.", "_test.rs", "/test_"])

if ext.lower() in SOURCE_EXTS and not is_test:
    current_lines = content.count("\n") + (1 if content and not content.endswith("\n") else 0)
    estimated = None

    if isinstance(patch_line_delta, int):
        estimated = current_lines + patch_line_delta
    elif old_string and new_string:
        old_lines = old_string.count("\n") + (1 if old_string and not old_string.endswith("\n") else 0)
        new_lines = new_string.count("\n") + (1 if new_string and not new_string.endswith("\n") else 0)
        if replace_all:
            occurrences = content.count(old_string)
            estimated = current_lines - (old_lines * occurrences) + (new_lines * occurrences)
        else:
            estimated = current_lines - old_lines + new_lines

    if estimated is None:
        print("OK")
        sys.exit(0)

    limit = int(os.environ.get("VG_U16_BASE_LIMIT", "800") or "800")
    dir_path = os.path.dirname(os.path.abspath(file_path))
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

    warn_limit = int(os.environ.get("VG_U16_WARN_LIMIT", "400") or "400")
    if limit > int(os.environ.get("VG_U16_BASE_LIMIT", "800") or "800"):
        warn_limit = limit
    else:
        warn_limit = min(warn_limit, limit)

    if estimated > limit:
        print(f"U16_OVER_LIMIT:{estimated}:{limit}")
        sys.exit(0)
    if warn_limit < limit and estimated > warn_limit:
        print(f"U16_OVER_TYPICAL:{estimated}:{warn_limit}:{limit}")
        sys.exit(0)

print("OK")
' <<< "$INPUT" 2>/dev/null || echo -e "ERROR\n\nERROR")

CHECK_STATUS=$(echo "$CHECK_RESULT" | sed -n '1p')
FILE_PATH=$(echo "$CHECK_RESULT" | sed -n '2p')
DETAIL=$(echo "$CHECK_RESULT" | sed -n '3p')

# Malformed hook input is security-sensitive: fail closed instead of treating it
# as an empty/no-op edit request.
if [[ "$CHECK_STATUS" == "ERROR" && "$DETAIL" == "MALFORMED_JSON" ]]; then
  vg_log "pre-edit-guard" "Edit" "block" "Malformed hook input" ""
  vg_json_output_kv decision block reason "VIBEGUARD interception: malformed PreToolUse(Edit) hook input. The edit request could not be validated, so it was blocked instead of being treated as a safe skip."
  exit 0
fi

# No file_path → release
if [[ "$CHECK_STATUS" != "CHECK" ]]; then
  exit 0
fi

if [[ "$DETAIL" == "TEST_INFRA_PROTECTED" ]]; then
  vg_log "pre-edit-guard" "Edit" "block" "Test Infrastructure File Protection (W-12)" "$FILE_PATH"
  vg_json_output_kv decision block reason "VIBEGUARD W-12 interception: Modification of test infrastructure files - ${FILE_PATH} is prohibited. AI agents must not modify test framework configuration files such as conftest.py/jest.config/pytest.ini/.coveragerc. Such modifications may cause tests to be bypassed instead of actually fixing code problems. Please fix the code under test rather than manipulating the test framework."
  exit 0
fi

if [[ "$DETAIL" == "FILE_NOT_FOUND" ]]; then
  # Surface likely candidates by basename stem so the agent can correct path
  # hallucinations on the spot instead of re-guessing.
  CANDIDATES=""
  CANDIDATE_LOOKUP_ERROR=""
  if [[ "${VIBEGUARD_PRE_EDIT_SUGGEST:-1}" == "1" ]]; then
    _MISSING_BASENAME=$(basename "$FILE_PATH")
    _MISSING_STEM="${_MISSING_BASENAME%.*}"
    if [[ -n "$_MISSING_STEM" ]]; then
      _CANDIDATE_REPO=$(git rev-parse --show-toplevel 2>/dev/null || true)
      if [[ -n "$_CANDIDATE_REPO" ]]; then
        _CANDIDATE_FILES=""
        if ! _CANDIDATE_FILES=$(git -C "$_CANDIDATE_REPO" ls-files 2>&1); then
          CANDIDATE_LOOKUP_ERROR=$(printf '%s' "$_CANDIDATE_FILES" | sed -n '1p')
          [[ -z "$CANDIDATE_LOOKUP_ERROR" ]] && CANDIDATE_LOOKUP_ERROR="git ls-files exited non-zero"
        else
          CANDIDATES=$(printf '%s\n' "$_CANDIDATE_FILES" \
          | { grep -iF -- "/$_MISSING_STEM" 2>/dev/null || true; } \
          | head -3 \
          | sed "s|^|  ${_CANDIDATE_REPO}/|")
        fi
      fi
    fi
  fi
  vg_log "pre-edit-guard" "Edit" "block" "File does not exist" "$FILE_PATH"
  if [[ -n "$CANDIDATES" ]]; then
    vg_json_output_kv decision block reason "VIBEGUARD interception: File does not exist - ${FILE_PATH}. Likely candidates (by basename stem '${_MISSING_STEM}'):
${CANDIDATES}
Verify which (if any) matches before retrying; do not re-guess the original path. Set VIBEGUARD_PRE_EDIT_SUGGEST=0 to disable candidate hints."
  elif [[ -n "$CANDIDATE_LOOKUP_ERROR" ]]; then
    vg_json_output_kv decision block reason "VIBEGUARD interception: File does not exist - ${FILE_PATH}. Could not search tracked files for similar paths: ${CANDIDATE_LOOKUP_ERROR}. The AI may have hallucinated the path. Use Glob/Grep to search manually before retrying."
  else
    vg_json_output_kv decision block reason "VIBEGUARD interception: File does not exist - ${FILE_PATH}. No similar tracked files found by basename stem. The AI may have hallucinated the path. Use Glob/Grep with a different basename before retrying."
  fi
  exit 0
fi

if [[ "$DETAIL" == "OLD_STRING_NOT_FOUND" ]]; then
  vg_log "pre-edit-guard" "Edit" "block" "old_string does not exist" "$FILE_PATH"
  vg_json_output_kv decision block reason "VIBEGUARD interception: old_string does not exist in the file - the AI may have hallucinated the file content. Please use the Read tool to read the file first to confirm that the content to be replaced actually exists."
  exit 0
fi

if [[ "$DETAIL" == U16_OVER_LIMIT:* ]]; then
  _U16_EST=$(echo "$DETAIL" | cut -d: -f2)
  _U16_LIM=$(echo "$DETAIL" | cut -d: -f3)
  vg_log "pre-edit-guard" "Edit" "block" "U-16 file size: ${_U16_EST} > ${_U16_LIM}" "$FILE_PATH"
  vg_json_output_kv decision block reason "VIBEGUARD [U-16] block: this edit would bring ${FILE_PATH##*/} to ~${_U16_EST} lines (limit: ${_U16_LIM}). Split the file into focused submodules before adding more code. Do NOT proceed with this edit."
  exit 0
fi

if [[ "$DETAIL" == U16_OVER_TYPICAL:* ]]; then
  _U16_EST=$(echo "$DETAIL" | cut -d: -f2)
  _U16_WARN=$(echo "$DETAIL" | cut -d: -f3)
  _U16_LIM=$(echo "$DETAIL" | cut -d: -f4)
  vg_log "pre-edit-guard" "Edit" "warn" "U-16 file size advisory: ${_U16_EST} > ${_U16_WARN}" "$FILE_PATH"
  VG_U16_FILE="${FILE_PATH##*/}" \
  VG_U16_LINES="$_U16_EST" \
  VG_U16_WARN="$_U16_WARN" \
  VG_U16_LIMIT="$_U16_LIM" \
  python3 - <<'PY'
import json
import os

file_name = os.environ.get("VG_U16_FILE", "file")
line_count = os.environ.get("VG_U16_LINES", "0")
warn_limit = os.environ.get("VG_U16_WARN", "400")
hard_limit = os.environ.get("VG_U16_LIMIT", "800")
context = (
    f"VIBEGUARD [U-16] [advisory] [this-file] OBSERVATION: this edit would leave {file_name} "
    f"with {line_count} lines, exceeding the {warn_limit}-line typical range but staying "
    f"under the {hard_limit}-line hard limit\n"
    "SCOPE: keep the current change localized; plan a split if this file keeps growing\n"
    "ACTION: NONE — advisory only, continue without acknowledgement"
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "additionalContext": context,
    }
}, ensure_ascii=False))
PY
  exit 0
fi

# Pass all checks → Release
vg_log "pre-edit-guard" "Edit" "pass" "" "$FILE_PATH"
exit 0
