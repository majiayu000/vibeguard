#!/usr/bin/env bash
# VibeGuard PreToolUse(Write) Hook
#
# 分级策略：
#   - 编辑已有文件 → 放行
#   - 新建配置/文档/测试文件 → 放行
#   - 新建源码文件（.rs/.py/.ts/.js/.go/.jsx/.tsx）→ 拦截（要求先搜后写）
#
# 默认 warn 模式：提醒先搜后写（L1 约束由 PostToolUse 重复检测兜底）
# 设置 VIBEGUARD_WRITE_MODE=block 可升级为硬拦截模式

set -euo pipefail

source "$(dirname "$0")/log.sh"

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
  vg_log "pre-write-guard" "Write" "block" "测试基础设施文件保护 (W-12)" "$FILE_PATH"
  cat <<'EOF'
{
  "decision": "block",
  "reason": "[W-12] [block] [this-edit] OBSERVATION: writing to test infrastructure file blocked (conftest.py/jest.config/pytest.ini/.coveragerc/babel.config)\nFIX: Fix the production code that is failing — do not manipulate test framework configuration"
}
EOF
  exit 0
fi

# 文件已存在（编辑） → 放行
if [[ -e "$FILE_PATH" ]]; then
  exit 0
fi

# 提取文件名和扩展名
BASENAME=$(basename "$FILE_PATH")
EXT="${BASENAME##*.}"

# 放行列表：配置、文档、锁文件、测试文件
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

# 放行：测试目录下的文件
case "$FILE_PATH" in
  */tests/*|*/test/*|*/__tests__/*|*/spec/*|*/fixtures/*|*/mocks/*)
    exit 0 ;;
esac

# 源码文件：检查是否需要拦截
if ! vg_is_source_file "$FILE_PATH"; then
  exit 0
fi

# --- 源码文件：提醒先搜后写 ---
# 默认 warn（提醒），设置 VIBEGUARD_WRITE_MODE=block 可升级为硬拦截
MODE="${VIBEGUARD_WRITE_MODE:-warn}"

if [[ "$MODE" == "block" ]]; then
  vg_log "pre-write-guard" "Write" "block" "新源码文件未搜索" "$FILE_PATH"
  cat <<'EOF'
{
  "decision": "block",
  "reason": "[L1] [block] [this-edit] OBSERVATION: new source file creation blocked — required search not performed\nFIX: 1) Use Grep to search for same-named functions/classes/structs 2) Use Glob to search for same-named files 3) If similar functionality exists, extend the existing file\nDO NOT: Create this file without completing the required search"
}
EOF
else
  vg_log "pre-write-guard" "Write" "warn" "新源码文件提醒" "$FILE_PATH"
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "[L1] [review] [this-edit] OBSERVATION: new source file creation without prior search\nFIX: 1) Use Grep to search for same-named functions/classes/structs 2) Use Glob to search for same-named files. Only proceed after confirming no duplicates exist\nDO NOT: Create this file without completing the search steps above"
  }
}
EOF
fi
