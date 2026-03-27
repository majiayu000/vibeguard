#!/usr/bin/env bash
# VibeGuard PreToolUse(Edit) Hook
#
# 编辑文件前的防幻觉检查：
#   - 检测编辑的文件是否存在（防止 AI 编辑不存在的文件路径）
#   - 检测 old_string 是否真的在文件中（防止 AI 幻觉编辑内容）

set -euo pipefail

source "$(dirname "$0")/log.sh"

INPUT=$(cat)

# 直接在 Python 中完成全部检查，避免 bash 变量传递破坏 old_string
# （<<<heredoc 追加 \n、$() 吞尾部换行、echo 转义特殊字符）
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

# 无 file_path 或解析错误 → 放行
if [[ "$CHECK_STATUS" != "CHECK" ]]; then
  exit 0
fi

if [[ "$DETAIL" == "TEST_INFRA_PROTECTED" ]]; then
  vg_log "pre-edit-guard" "Edit" "block" "测试基础设施文件保护 (W-12)" "$FILE_PATH"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD W-12 拦截：禁止修改测试基础设施文件 — ${FILE_PATH}。AI 代理不得修改 conftest.py/jest.config/pytest.ini/.coveragerc 等测试框架配置文件，此类修改可能导致测试被绕过而非真正修复代码问题。请修复被测代码，而非操纵测试框架。"
}
BLOCK_EOF
  exit 0
fi

if [[ "$DETAIL" == "FILE_NOT_FOUND" ]]; then
  vg_log "pre-edit-guard" "Edit" "block" "文件不存在" "$FILE_PATH"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD 拦截：文件不存在 — ${FILE_PATH}。AI 可能幻觉了文件路径。请先用 Glob/Grep 搜索正确的文件路径。"
}
BLOCK_EOF
  exit 0
fi

if [[ "$DETAIL" == "OLD_STRING_NOT_FOUND" ]]; then
  vg_log "pre-edit-guard" "Edit" "block" "old_string 不存在" "$FILE_PATH"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD 拦截：old_string 在文件中不存在 — AI 可能幻觉了文件内容。请先用 Read 工具读取文件，确认要替换的内容确实存在。"
}
BLOCK_EOF
  exit 0
fi

# 通过所有检查 → 放行
vg_log "pre-edit-guard" "Edit" "pass" "" "$FILE_PATH"
exit 0
