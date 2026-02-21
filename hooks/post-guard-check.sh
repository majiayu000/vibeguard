#!/usr/bin/env bash
# VibeGuard PostToolUse(guard_check) Hook
# 当 guard_check 发现问题时，注入修复流程提醒
# 全部 PASS 时静默退出，不干扰

set -euo pipefail

source "$(dirname "$0")/log.sh"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 从 stdin 读取 JSON
INPUT=$(cat)

# 提取 tool_result 文本
TOOL_RESULT=$(echo "$INPUT" | vg_json_field "tool_result")

# 如果无法解析或没有发现问题，静默退出
if [[ -z "$TOOL_RESULT" ]] || ! echo "$TOOL_RESULT" | grep -q "ISSUES FOUND"; then
  vg_log "post-guard-check" "guard_check" "pass" "" ""
  exit 0
fi

vg_log "post-guard-check" "guard_check" "warn" "ISSUES FOUND" ""

# 检测语言（从 tool_input 中提取）
LANGUAGE=$(echo "$INPUT" | vg_json_field "tool_input.language")

RULES_HINT=""
if [[ -n "$LANGUAGE" ]] && [[ -f "${REPO_DIR}/rules/${LANGUAGE}.md" ]]; then
  RULES_HINT="2. 读取 ${REPO_DIR}/rules/${LANGUAGE}.md 了解 FIX/SKIP/DEFER 判断标准和修复模式"
else
  RULES_HINT="2. 读取 ${REPO_DIR}/rules/ 下对应语言的规则文件，了解 FIX/SKIP/DEFER 判断标准和修复模式"
fi

# 输出修复流程提醒（通过环境变量传参，避免注入）
VG_RULES_HINT="$RULES_HINT" python3 -c '
import json, os

rules_hint = os.environ.get("VG_RULES_HINT", "")
context = f"""VIBEGUARD 守卫发现了问题。请按以下流程处理：
1. 分析上方发现，按文件和类型分组
{rules_hint}
3. 基于发现和项目上下文，生成修复计划（FIX/SKIP/DEFER）
4. 按计划逐项修复
5. 修复后重新运行 guard_check 验证"""

output = {
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": context
    }
}
print(json.dumps(output, ensure_ascii=False))
'
