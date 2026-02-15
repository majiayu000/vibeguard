#!/usr/bin/env bash
# VibeGuard PreToolUse(Write) Hook
#
# 分级策略：
#   - 编辑已有文件 → 放行
#   - 新建配置/文档/测试文件 → 放行
#   - 新建源码文件（.rs/.py/.ts/.js/.go/.jsx/.tsx）→ 注入上下文提醒
#
# 默认 warn 模式：注入 additionalContext 提醒 agent 先搜后写，不阻止操作
# 设置 VIBEGUARD_WRITE_MODE=block 可升级为硬拦截模式

set -euo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('tool_input', {}).get('file_path', ''))
" 2>/dev/null || echo "")

# 无法解析或文件已存在（编辑） → 放行
if [[ -z "$FILE_PATH" ]] || [[ -e "$FILE_PATH" ]]; then
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
SOURCE_EXTS="rs py ts js tsx jsx go java kt swift rb"
IS_SOURCE=false
for ext in $SOURCE_EXTS; do
  if [[ "$EXT" == "$ext" ]]; then
    IS_SOURCE=true
    break
  fi
done

if [[ "$IS_SOURCE" != true ]]; then
  exit 0
fi

# --- 源码文件：注入提醒，指导 agent 先搜后写 ---
# 默认 warn（注入上下文提醒），设置 VIBEGUARD_WRITE_MODE=block 可硬拦截
MODE="${VIBEGUARD_WRITE_MODE:-warn}"

if [[ "$MODE" == "block" ]]; then
  cat <<'EOF'
{
  "decision": "block",
  "reason": "VIBEGUARD 拦截：创建新源码文件前必须先搜索已有实现。修复步骤：1) 用 Grep 搜索同名函数/类/结构体；2) 用 Glob 搜索同名或相似文件名；3) 如已有类似功能则扩展现有文件。设置 VIBEGUARD_WRITE_MODE=warn 可降级为提醒模式。"
}
EOF
else
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "VIBEGUARD 先搜后写：你正在创建新源码文件。如果还没搜索过，请先用 Grep/Glob 确认项目中无类似实现再继续。如已搜索确认无重复，可忽略此提醒。"
  }
}
EOF
fi
