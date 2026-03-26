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
BASENAME=$(basename "$FILE_PATH")
_is_test_infra=false
case "$BASENAME" in
  conftest.py|pytest.ini|.coveragerc|setup.cfg|\
  jest.config.js|jest.config.ts|jest.config.cjs|jest.config.mjs|jest.config.json|\
  vitest.config.js|vitest.config.ts|vitest.config.mts|\
  karma.config.js|karma.config.ts|\
  babel.config.js|babel.config.ts|babel.config.cjs|babel.config.json)
    _is_test_infra=true ;;
esac
if [[ "$_is_test_infra" == "true" ]]; then
  vg_log "pre-write-guard" "Write" "block" "测试基础设施文件保护 (W-12)" "$FILE_PATH"
  cat <<'EOF'
{
  "decision": "block",
  "reason": "VIBEGUARD W-12 拦截：禁止写入测试基础设施文件。AI 代理不得创建或覆盖 conftest.py/jest.config/pytest.ini/.coveragerc/babel.config 等测试框架配置文件，此类修改可能导致测试被绕过而非真正修复代码问题。请修复被测代码，而非操纵测试框架。"
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
  "reason": "VIBEGUARD 拦截：创建新源码文件前必须先搜索已有实现。修复步骤：1) 用 Grep 搜索同名函数/类/结构体；2) 用 Glob 搜索同名或相似文件名；3) 如已有类似功能则扩展现有文件。设置 VIBEGUARD_WRITE_MODE=warn 可降级为提醒模式。"
}
EOF
else
  vg_log "pre-write-guard" "Write" "warn" "新源码文件提醒" "$FILE_PATH"
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "VIBEGUARD 先搜后写（L1）：你正在创建新源码文件。在继续之前，你必须先执行以下搜索：1) Grep 搜索同名函数/类/结构体 2) Glob 搜索同名或相似文件名。只有搜索结果确认无重复后才能继续创建。"
  }
}
EOF
fi
