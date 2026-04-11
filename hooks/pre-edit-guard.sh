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

if not file_path:
    print("PASS")
    print("")
    sys.exit(0)

print("CHECK")
print(file_path)

# W-12: Block edits to test infrastructure files
# Resolve symlinks first to prevent bypass via aliases (e.g. safe.txt -> conftest.py)
real_path = os.path.realpath(file_path)
# Use lowercased basename for case-insensitive filesystem safety (e.g. default macOS HFS+)
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

if old_string:
    with open(file_path, "r", errors="replace") as f:
        content = f.read()
    if old_string not in content:
        print("OLD_STRING_NOT_FOUND")
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

# Pass all checks → Release
vg_log "pre-edit-guard" "Edit" "pass" "" "$FILE_PATH"
exit 0
