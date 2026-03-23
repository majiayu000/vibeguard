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
import json, sys

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

import os
if not os.path.isfile(file_path):
    print("FILE_NOT_FOUND")
    sys.exit(0)

# Protected test infrastructure files (W-12 attack vectors 5-7)
import re as _re
_PROTECTED = {
    "conftest.py", "pytest.ini", ".coveragerc",
    "jest.config.js", "jest.config.ts", "jest.config.mjs", "jest.config.cjs",
    "jest.config.json",
}

def _inode_key(p):
    try:
        s = os.stat(p)
        return (s.st_dev, s.st_ino)
    except OSError:
        return None

def _is_hardlink_to_protected(path, protected_names):
    """Return True if path shares an inode with any protected file found
    by walking up to 5 parent directories. Catches hard-link bypasses."""
    try:
        st = os.stat(path)
        if st.st_nlink < 2:
            return False  # single link cannot be a hard link to another file
        target_key = (st.st_dev, st.st_ino)
    except OSError:
        return False
    check_dir = os.path.dirname(os.path.abspath(path))
    for _ in range(5):
        for pname in protected_names:
            k = _inode_key(os.path.join(check_dir, pname))
            if k and k == target_key:
                return True
        parent = os.path.dirname(check_dir)
        if parent == check_dir:
            break
        check_dir = parent
    return False

# Use symlink-resolved path for basename check (handles symlinks),
# plus inode comparison for hard-link bypass detection.
_real_path = os.path.realpath(file_path)
_real_bn = os.path.basename(_real_path)
_is_test_tsconfig = (
    _real_bn == "tsconfig.json" and
    bool(_re.search(r"(?:^|[/\\])(test|spec|__tests__)(?:[/\\]|$)",
                    _real_path, _re.IGNORECASE))
)
if (_real_bn in _PROTECTED or _is_test_tsconfig
        or _is_hardlink_to_protected(file_path, _PROTECTED)):
    print("PROTECTED_INFRA")
    sys.exit(0)

if old_string:
    with open(file_path, "r") as f:
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

if [[ "$DETAIL" == "PROTECTED_INFRA" ]]; then
  vg_log "pre-edit-guard" "Edit" "block" "受保护的测试基础设施文件" "$FILE_PATH"
  cat <<BLOCK_EOF
{
  "decision": "block",
  "reason": "VIBEGUARD 拦截：${FILE_PATH} 是受保护的测试基础设施文件（W-12）。AI 代理不得修改 conftest.py / jest.config.* / pytest.ini / .coveragerc 等文件，以防止 reward hacking（Baker et al. 攻击向量 5-7）。如需合法修改，请用户直接编辑。"
}
BLOCK_EOF
  exit 0
fi

# 通过所有检查 → 放行
vg_log "pre-edit-guard" "Edit" "pass" "" "$FILE_PATH"
exit 0
