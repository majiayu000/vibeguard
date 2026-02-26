#!/usr/bin/env bash
# VibeGuard Stop Guard — 完成前验证门禁
#
# 在 Stop 事件触发时检查是否有未验证的源码变更。
# 有变更则提醒 Claude 完成验证，无变更或门禁已触发过则放行。
#
# exit 0 = 放行（允许停止）
# exit 1 = 阻止（Claude 继续，stdout 作为反馈）
set -euo pipefail
source "$(dirname "$0")/log.sh"

FLAG_FILE="${HOME}/.vibeguard/.stop_gate_active"

# 防无限循环：门禁已触发过 → 直接放行
if [[ -f "$FLAG_FILE" ]]; then
  rm -f "$FLAG_FILE"
  vg_log "stop-guard" "Stop" "pass" "gate already triggered once" ""
  exit 0
fi

# 不在 git 仓库 → 放行
if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  exit 0
fi

# 收集未提交的源码变更
SOURCE_CHANGES=""
for ext in $VG_SOURCE_EXTS; do
  files=$(git diff --name-only -- "*.${ext}" 2>/dev/null || true)
  staged=$(git diff --cached --name-only -- "*.${ext}" 2>/dev/null || true)
  if [[ -n "$files" ]]; then
    SOURCE_CHANGES="${SOURCE_CHANGES}${files}"$'\n'
  fi
  if [[ -n "$staged" ]]; then
    SOURCE_CHANGES="${SOURCE_CHANGES}${staged}"$'\n'
  fi
done

# 去重去空
SOURCE_CHANGES=$(echo "$SOURCE_CHANGES" | sort -u | sed '/^$/d')

# 无源码变更 → 放行
if [[ -z "$SOURCE_CHANGES" ]]; then
  exit 0
fi

# 有变更 → 设置门禁标志（下次直接放行）
mkdir -p "$(dirname "$FLAG_FILE")"
touch "$FLAG_FILE"

# 检测项目类型
VERIFY_HINT=""
if [[ -f "Cargo.toml" ]]; then
  VERIFY_HINT="Rust: cargo check && cargo test"
elif [[ -f "tsconfig.json" ]]; then
  VERIFY_HINT="TypeScript: npx tsc --noEmit && npm test"
elif [[ -f "package.json" ]]; then
  VERIFY_HINT="JavaScript: npm test"
elif [[ -f "go.mod" ]]; then
  VERIFY_HINT="Go: go build ./... && go test ./..."
elif [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]] || [[ -f "requirements.txt" ]]; then
  VERIFY_HINT="Python: python -m pytest"
fi

FILE_COUNT=$(echo "$SOURCE_CHANGES" | wc -l | tr -d ' ')
FILE_LIST=$(echo "$SOURCE_CHANGES" | head -5 | tr '\n' ' ')

vg_log "stop-guard" "Stop" "gate" "uncommitted source changes: ${FILE_COUNT} files" "$FILE_LIST"

echo "VibeGuard Stop Gate: 检测到 ${FILE_COUNT} 个源码文件有未提交变更。" >&2
echo "请确认已完成验证后再结束。" >&2
if [[ -n "$VERIFY_HINT" ]]; then
  echo "建议验证: ${VERIFY_HINT}" >&2
fi
echo "变更文件: ${FILE_LIST}" >&2
exit 2
