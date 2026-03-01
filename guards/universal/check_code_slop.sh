#!/usr/bin/env bash
# VibeGuard Guard — AI 代码垃圾检测
#
# 检测 AI 常见垃圾模式：
#   - 未使用的 import
#   - 空 catch/except 块
#   - 超过 30 天未处理的 TODO/FIXME
#   - 死代码标记（unreachable、never）
#   - 遗留的调试代码（console.log、print、dbg!）
#
# 用法：
#   bash check_code_slop.sh [target_dir]    # 扫描指定目录
#   bash check_code_slop.sh                 # 扫描当前目录

set -euo pipefail

TARGET_DIR="${1:-.}"
ISSUES=0

yellow() { printf '\033[33m[SLOP] %s\033[0m\n' "$1"; }
red() { printf '\033[31m[SLOP] %s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

# 排除目录
EXCLUDE="--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=target --exclude-dir=dist --exclude-dir=build --exclude-dir=__pycache__ --exclude-dir=.venv --exclude-dir=vendor"

echo "扫描目录: ${TARGET_DIR}"
echo "---"

# 1. 空 catch/except 块
echo "检查空异常处理块..."
EMPTY_CATCH=$(grep -rn $EXCLUDE \
  -E '(catch\s*\([^)]*\)\s*\{\s*\}|except(\s+\w+)?:\s*$|except.*:\s*pass\s*$)' \
  "$TARGET_DIR" --include='*.py' --include='*.ts' --include='*.js' --include='*.tsx' --include='*.jsx' \
  2>/dev/null || true)
if [[ -n "$EMPTY_CATCH" ]]; then
  COUNT=$(echo "$EMPTY_CATCH" | wc -l | tr -d ' ')
  red "空异常处理块: ${COUNT} 处"
  echo "$EMPTY_CATCH" | head -5
  [[ "$COUNT" -gt 5 ]] && echo "  ... 还有 $((COUNT - 5)) 处"
  ISSUES=$((ISSUES + COUNT))
fi

# 2. 遗留调试代码
echo "检查遗留调试代码..."
DEBUG_CODE=$(grep -rn $EXCLUDE \
  -E '^\s*(console\.(log|debug|info)\(|print\(|println!\(|dbg!\(|puts |p |pp )' \
  "$TARGET_DIR" --include='*.py' --include='*.ts' --include='*.js' --include='*.tsx' --include='*.jsx' --include='*.rs' --include='*.rb' --include='*.go' \
  2>/dev/null | grep -v '// keep' | grep -v '# keep' | grep -v 'logger\.' || true)
if [[ -n "$DEBUG_CODE" ]]; then
  COUNT=$(echo "$DEBUG_CODE" | wc -l | tr -d ' ')
  yellow "遗留调试代码: ${COUNT} 处"
  echo "$DEBUG_CODE" | head -5
  [[ "$COUNT" -gt 5 ]] && echo "  ... 还有 $((COUNT - 5)) 处"
  ISSUES=$((ISSUES + COUNT))
fi

# 3. 过期 TODO/FIXME（git blame 检查日期）
echo "检查过期 TODO/FIXME..."
TODOS=$(grep -rn $EXCLUDE \
  -E '(TODO|FIXME|HACK|XXX)\b' \
  "$TARGET_DIR" --include='*.py' --include='*.ts' --include='*.js' --include='*.tsx' --include='*.jsx' --include='*.rs' --include='*.go' \
  2>/dev/null || true)
if [[ -n "$TODOS" ]]; then
  STALE=0
  CUTOFF=$(date -v-30d +%s 2>/dev/null || date -d "30 days ago" +%s 2>/dev/null || echo "0")
  while IFS= read -r line; do
    FILE=$(echo "$line" | cut -d: -f1)
    LINE_NUM=$(echo "$line" | cut -d: -f2)
    if [[ -f "$FILE" ]] && git log -1 --format=%at -L "${LINE_NUM},${LINE_NUM}:${FILE}" 2>/dev/null | head -1 | grep -qE '^[0-9]+$'; then
      COMMIT_TS=$(git log -1 --format=%at -L "${LINE_NUM},${LINE_NUM}:${FILE}" 2>/dev/null | head -1)
      if [[ "$COMMIT_TS" -lt "$CUTOFF" ]] 2>/dev/null; then
        STALE=$((STALE + 1))
      fi
    fi
  done <<< "$(echo "$TODOS" | head -20)"
  if [[ "$STALE" -gt 0 ]]; then
    yellow "过期 TODO/FIXME (>30天): ${STALE} 处"
    ISSUES=$((ISSUES + STALE))
  fi
  echo "  TODO/FIXME 总数: $(echo "$TODOS" | wc -l | tr -d ' ')"
fi

# 4. 死代码标记
echo "检查死代码标记..."
DEAD_CODE=$(grep -rn $EXCLUDE \
  -E '(unreachable!|todo!|unimplemented!|#\[allow\(dead_code\)\]|// @ts-ignore|# type: ignore|# noqa)' \
  "$TARGET_DIR" --include='*.py' --include='*.ts' --include='*.js' --include='*.rs' \
  2>/dev/null || true)
if [[ -n "$DEAD_CODE" ]]; then
  COUNT=$(echo "$DEAD_CODE" | wc -l | tr -d ' ')
  yellow "死代码/抑制标记: ${COUNT} 处"
  echo "$DEAD_CODE" | head -5
  [[ "$COUNT" -gt 5 ]] && echo "  ... 还有 $((COUNT - 5)) 处"
  ISSUES=$((ISSUES + COUNT))
fi

# 5. 超长文件 (> 300 行)
echo "检查超长文件..."
LONG_FILES=$(find "$TARGET_DIR" \
  -name '*.py' -o -name '*.ts' -o -name '*.js' -o -name '*.tsx' -o -name '*.rs' -o -name '*.go' \
  2>/dev/null | while read -r f; do
    [[ "$f" == *node_modules* || "$f" == *target* || "$f" == *dist* || "$f" == *.git* ]] && continue
    LINES=$(wc -l < "$f" 2>/dev/null || echo 0)
    [[ "$LINES" -gt 300 ]] && echo "  ${f}: ${LINES} 行"
  done || true)
if [[ -n "$LONG_FILES" ]]; then
  COUNT=$(echo "$LONG_FILES" | wc -l | tr -d ' ')
  yellow "超长文件 (>300行): ${COUNT} 个"
  echo "$LONG_FILES" | head -5
  ISSUES=$((ISSUES + COUNT))
fi

echo ""
echo "---"
if [[ "$ISSUES" -gt 0 ]]; then
  red "发现 ${ISSUES} 个代码垃圾问题"
  exit 1
else
  green "未发现代码垃圾"
  exit 0
fi
