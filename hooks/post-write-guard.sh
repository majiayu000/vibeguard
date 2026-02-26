#!/usr/bin/env bash
# VibeGuard PostToolUse(Write) Hook
#
# 新源码文件创建后，检测项目中是否存在重复实现：
#   1. 同名文件（不同目录下出现同名源码文件）
#   2. 关键定义重复（struct/class/interface/func 在其他文件中已存在）
#
# 事后审查，不阻止操作，只输出警告。
# 与 pre-write-guard（warn 模式）配合：前置提醒 + 后置审查。

set -euo pipefail

source "$(dirname "$0")/log.sh"

INPUT=$(cat)

RESULT=$(echo "$INPUT" | vg_json_two_fields "tool_input.file_path" "tool_input.content")

FILE_PATH=$(echo "$RESULT" | head -1)
CONTENT=$(echo "$RESULT" | tail -n +2)

if [[ -z "$FILE_PATH" ]] || [[ -z "$CONTENT" ]]; then
  exit 0
fi

# 提取文件名和扩展名
BASENAME=$(basename "$FILE_PATH")
EXT="${BASENAME##*.}"

# 只检查源码文件
if ! vg_is_source_file "$FILE_PATH"; then
  vg_log "post-write-guard" "Write" "pass" "非源码文件" "$FILE_PATH"
  exit 0
fi

# 找到项目根目录（向上找 .git）
PROJECT_DIR="$FILE_PATH"
while [[ "$PROJECT_DIR" != "/" ]]; do
  PROJECT_DIR=$(dirname "$PROJECT_DIR")
  if [[ -d "$PROJECT_DIR/.git" ]]; then
    break
  fi
done

if [[ "$PROJECT_DIR" == "/" ]]; then
  vg_log "post-write-guard" "Write" "pass" "无 git 项目" "$FILE_PATH"
  exit 0
fi

WARNINGS=""

# 扫描预算：避免在大仓库中每次写入都触发高开销全量扫描
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

# --- 检查 1: 同名文件 ---
# 在项目中搜索同名文件（排除 node_modules、.git、target、vendor 等）
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
    2>/dev/null | head -"${MAX_MATCHES}" || true)
fi

if [[ -n "$SAME_NAME_FILES" ]]; then
  FILE_LIST=$(echo "$SAME_NAME_FILES" | tr '\n' ', ' | sed 's/,$//')
  WARNINGS="[L1-重复文件] 项目中已存在同名文件: ${FILE_LIST}。请确认是否应该扩展已有文件而非新建。"
fi

if [[ "${SCAN_DEGRADED}" -eq 1 ]]; then
  WARNINGS="${WARNINGS:+${WARNINGS} }[L1-扫描降级] 项目文件数 ${FILE_COUNT} 超过阈值 ${MAX_SCAN_FILES}，已跳过重复定义深度扫描。"
fi

# --- 检查 2: 关键定义重复 ---
# 从新文件内容中提取关键定义名称
DEFINITIONS=$(echo "$CONTENT" | python3 -c "
import sys, re

content = sys.stdin.read()
names = set()

# 提取各语言的关键定义
patterns = [
    r'(?:pub\s+)?(?:struct|enum|trait)\s+(\w+)',    # Rust
    r'(?:class|interface)\s+(\w+)',                   # Python/TS/Java/Go
    r'(?:type)\s+(\w+)\s+(?:struct|interface)',       # Go
    r'(?:export\s+)?(?:function|const|class)\s+(\w+)',# JS/TS
    r'(?:def)\s+(\w+)\s*\(',                          # Python
    r'(?:pub\s+)?(?:fn)\s+(\w+)',                     # Rust
    r'(?:func)\s+(\w+)',                              # Go
]

for p in patterns:
    for m in re.finditer(p, content):
        name = m.group(1)
        # 过滤太短或太通用的名称
        if len(name) > 3 and name not in ('self', 'init', 'main', 'test', 'None', 'True', 'False', 'this', 'super'):
            names.add(name)

for name in sorted(names):
    print(name)
" 2>/dev/null || true)

if [[ -n "$DEFINITIONS" ]] && [[ "${SCAN_DEGRADED}" -eq 0 ]]; then
  DEFINITIONS=$(echo "$DEFINITIONS" | head -n "${MAX_SCAN_DEFS}")
  DUPLICATE_DEFS=""
  while IFS= read -r defname; do
    # 在项目中搜索这个定义名（排除新文件自身）
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
      DUPLICATE_DEFS="${DUPLICATE_DEFS:+${DUPLICATE_DEFS} }${defname}(在 ${FOUND_LIST})"
    fi
  done <<< "$DEFINITIONS"

  if [[ -n "$DUPLICATE_DEFS" ]]; then
    WARNINGS="${WARNINGS:+${WARNINGS} }[L1-重复定义] 以下定义在项目中已存在: ${DUPLICATE_DEFS}。请确认是否重复实现，考虑复用已有代码。"
  fi
fi

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
        "additionalContext": "VIBEGUARD 重复检测：" + warnings
    }
}
print(json.dumps(result, ensure_ascii=False))
'
