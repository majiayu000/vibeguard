#!/usr/bin/env bash
# VibeGuard PreToolUse(Edit) Hook
#
# Anti-hallucination check before editing files:
# - Detect whether the edited file exists (prevents AI from editing non-existent file paths)
# - Check if old_string is actually in the file (to prevent AI hallucinating editing content)

set -euo pipefail

source "$(dirname "$0")/log.sh"
vg_start_timer

INPUT=$(cat)

# Complete all checks directly in Python to avoid bash variable passing from destroying old_string
# (<<<heredoc appends \n, $() swallows trailing newlines, echo escapes special characters)
CHECK_RESULT=$(python3 -c '
import json, sys, os, re
from pathlib import PurePath

data = json.load(sys.stdin)

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
is_test = any(p in file_path for p in ["/tests/", "_test.", ".test.", ".spec.", "_test.rs", "/test_"])

if ext.lower() in SOURCE_EXTS and not is_test and old_string and new_string:
    current_lines = content.count("\n")
    old_lines = old_string.count("\n")
    new_lines = new_string.count("\n")
    if replace_all:
        occurrences = content.count(old_string)
        estimated = current_lines - (old_lines * occurrences) + (new_lines * occurrences)
    else:
        estimated = current_lines - old_lines + new_lines

    limit = 800
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

    if estimated > limit:
        print(f"U16_OVER_LIMIT:{estimated}:{limit}")
        sys.exit(0)

print("OK")
' <<< "$INPUT" 2>/dev/null || echo -e "ERROR\n\nERROR")

CHECK_STATUS=$(echo "$CHECK_RESULT" | sed -n '1p')
FILE_PATH=$(echo "$CHECK_RESULT" | sed -n '2p')
DETAIL=$(echo "$CHECK_RESULT" | sed -n '3p')

# No file_path or parsing error → release
if [[ "$CHECK_STATUS" != "CHECK" ]]; then
  exit 0
fi

if [[ "$DETAIL" == "TEST_INFRA_PROTECTED" ]]; then
  vg_log "pre-edit-guard" "Edit" "block" "Test Infrastructure File Protection (W-12)" "$FILE_PATH"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD W-12 interception: Modification of test infrastructure files - ${FILE_PATH} is prohibited. AI agents must not modify test framework configuration files such as conftest.py/jest.config/pytest.ini/.coveragerc. Such modifications may cause tests to be bypassed instead of actually fixing code problems. Please fix the code under test rather than manipulating the test framework."
}
BLOCK_EOF
  exit 0
fi

if [[ "$DETAIL" == "FILE_NOT_FOUND" ]]; then
  vg_log "pre-edit-guard" "Edit" "block" "File does not exist" "$FILE_PATH"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD interception: File does not exist - ${FILE_PATH}. The AI may have hallucinated the file path. Please use Glob/Grep to search for the correct file path first."
}
BLOCK_EOF
  exit 0
fi

if [[ "$DETAIL" == "OLD_STRING_NOT_FOUND" ]]; then
  vg_log "pre-edit-guard" "Edit" "block" "old_string does not exist" "$FILE_PATH"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD interception: old_string does not exist in the file - the AI may have hallucinated the file content. Please use the Read tool to read the file first to confirm that the content to be replaced actually exists."
}
BLOCK_EOF
  exit 0
fi

if [[ "$DETAIL" == U16_OVER_LIMIT:* ]]; then
  _U16_EST=$(echo "$DETAIL" | cut -d: -f2)
  _U16_LIM=$(echo "$DETAIL" | cut -d: -f3)
  vg_log "pre-edit-guard" "Edit" "block" "U-16 file size: ${_U16_EST} > ${_U16_LIM}" "$FILE_PATH"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD [U-16] block: this edit would bring ${FILE_PATH##*/} to ~${_U16_EST} lines (limit: ${_U16_LIM}). Split the file into focused submodules before adding more code. Do NOT proceed with this edit."
}
BLOCK_EOF
  exit 0
fi

# Pass all checks → Release
vg_log "pre-edit-guard" "Edit" "pass" "" "$FILE_PATH"
exit 0
