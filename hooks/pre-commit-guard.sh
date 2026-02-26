#!/usr/bin/env bash
# VibeGuard Pre-Commit Guard — git commit 前自动守卫
#
# 安装到 .git/hooks/pre-commit 后，每次 git commit 自动运行。
# 只检查 staged 文件，只跑快速检查（< 10s），不跑完整 CI。
#
# 检查项：
#   - Rust: unwrap()/expect() in non-test code
#   - TS/JS: console.log/warn/error in non-test code
#   - Python: print() in non-test code
#   - 通用: 硬编码数据库路径
#   - 构建检查: cargo check / tsc --noEmit / go build
#
# exit 0 = 放行
# exit 1 = 阻止提交
#
# 跳过方式: VIBEGUARD_SKIP_PRECOMMIT=1 git commit -m "msg"

set -euo pipefail

# 允许跳过
if [[ "${VIBEGUARD_SKIP_PRECOMMIT:-0}" == "1" ]]; then
  exit 0
fi

# 定位 log.sh（支持 symlink 安装和直接调用两种场景）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/log.sh" ]]; then
  source "${SCRIPT_DIR}/log.sh"
elif [[ -n "${VIBEGUARD_DIR:-}" ]] && [[ -f "${VIBEGUARD_DIR}/hooks/log.sh" ]]; then
  source "${VIBEGUARD_DIR}/hooks/log.sh"
else
  # 无 log.sh 时提供 fallback，不阻塞提交
  vg_log() { :; }
  VG_SOURCE_EXTS="rs py ts js tsx jsx go java kt swift rb"
fi

# 超时硬限（秒）
TIMEOUT="${VIBEGUARD_PRECOMMIT_TIMEOUT:-10}"

# 收集 staged 的源码文件
STAGED_FILES=""
for ext in $VG_SOURCE_EXTS; do
  files=$(git diff --cached --name-only --diff-filter=ACM -- "*.${ext}" 2>/dev/null || true)
  if [[ -n "$files" ]]; then
    STAGED_FILES="${STAGED_FILES}${files}"$'\n'
  fi
done
STAGED_FILES=$(echo "$STAGED_FILES" | sort -u | sed '/^$/d')

# 无源码变更 → 放行
if [[ -z "$STAGED_FILES" ]]; then
  exit 0
fi

WARNINGS=""
FILE_COUNT=$(echo "$STAGED_FILES" | wc -l | tr -d ' ')

# --- 逐文件质量检查（只检查 staged diff） ---
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$file" ]] && continue

  # 获取 staged 内容（不是工作区内容）
  STAGED_CONTENT=$(git diff --cached -- "$file" | grep '^+' | grep -v '^+++' || true)
  [[ -z "$STAGED_CONTENT" ]] && continue

  # 判断是否测试文件
  IS_TEST=0
  case "$file" in
    */tests/*|*/test/*|*_test.rs|*_test.go|*.test.ts|*.test.tsx|*.test.js|*.test.jsx|*.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx|*/test_*.py) IS_TEST=1 ;;
  esac

  # Rust 检查
  if [[ "$file" == *.rs ]] && [[ $IS_TEST -eq 0 ]]; then
    UNWRAP_COUNT=$(echo "$STAGED_CONTENT" | grep -cE '\.(unwrap|expect)\(' 2>/dev/null || true)
    SAFE_COUNT=$(echo "$STAGED_CONTENT" | grep -cE '\.(unwrap_or|unwrap_or_else|unwrap_or_default)\(' 2>/dev/null || true)
    REAL=$((UNWRAP_COUNT - SAFE_COUNT))
    if [[ $REAL -gt 0 ]]; then
      WARNINGS="${WARNINGS}  ${file}: ${REAL} 个 unwrap()/expect()\n"
    fi
  fi

  # TS/JS 检查
  case "$file" in
    *.ts|*.tsx|*.js|*.jsx)
      if [[ $IS_TEST -eq 0 ]]; then
        CNT=$(echo "$STAGED_CONTENT" | grep -cE '\bconsole\.(log|warn|error)\(' 2>/dev/null || true)
        if [[ $CNT -gt 0 ]]; then
          WARNINGS="${WARNINGS}  ${file}: ${CNT} 个 console.log/warn/error\n"
        fi
      fi
      ;;
  esac

  # Python 检查
  if [[ "$file" == *.py ]] && [[ $IS_TEST -eq 0 ]]; then
    CNT=$(echo "$STAGED_CONTENT" | grep -cE '^\+\s*print\(' 2>/dev/null || true)
    if [[ $CNT -gt 0 ]]; then
      WARNINGS="${WARNINGS}  ${file}: ${CNT} 个 print()\n"
    fi
  fi

  # 通用：硬编码数据库路径
  if [[ $IS_TEST -eq 0 ]]; then
    if echo "$STAGED_CONTENT" | grep -qE '"[^"]*\.(db|sqlite)"' 2>/dev/null; then
      WARNINGS="${WARNINGS}  ${file}: 硬编码数据库路径\n"
    fi
  fi
done <<< "$STAGED_FILES"

# --- 快速构建检查（带超时） ---
BUILD_FAIL=""

run_with_timeout() {
  local cmd="$1"
  timeout "${TIMEOUT}" bash -c "$cmd" 2>&1 || {
    local code=$?
    if [[ $code -eq 124 ]]; then
      # 超时 → 跳过，不阻塞
      return 0
    fi
    return $code
  }
}

if [[ -f "Cargo.toml" ]]; then
  if ! run_with_timeout "cargo check --quiet 2>&1" >/dev/null 2>&1; then
    BUILD_FAIL="cargo check 失败"
  fi
elif [[ -f "tsconfig.json" ]]; then
  if ! run_with_timeout "npx tsc --noEmit 2>&1" >/dev/null 2>&1; then
    BUILD_FAIL="tsc --noEmit 失败"
  fi
elif [[ -f "go.mod" ]]; then
  if ! run_with_timeout "go build ./... 2>&1" >/dev/null 2>&1; then
    BUILD_FAIL="go build 失败"
  fi
fi

# --- 汇总结果 ---
if [[ -z "$WARNINGS" ]] && [[ -z "$BUILD_FAIL" ]]; then
  vg_log "pre-commit-guard" "git-commit" "pass" "staged ${FILE_COUNT} files, all clean" ""
  exit 0
fi

# 有问题 → 输出并阻止
echo "VibeGuard Pre-Commit Guard: 检测到问题"
echo "======================================="

if [[ -n "$WARNINGS" ]]; then
  echo ""
  echo "质量问题："
  echo -e "$WARNINGS"
fi

if [[ -n "$BUILD_FAIL" ]]; then
  echo ""
  echo "构建失败：${BUILD_FAIL}"
fi

echo ""
echo "修复后重新 git add && git commit"
echo "紧急跳过：VIBEGUARD_SKIP_PRECOMMIT=1 git commit -m \"msg\""

REASON="${WARNINGS:+quality issues}${BUILD_FAIL:+${WARNINGS:+, }${BUILD_FAIL}}"
DETAIL=$(echo "$STAGED_FILES" | head -5 | tr '\n' ' ')
vg_log "pre-commit-guard" "git-commit" "block" "$REASON" "$DETAIL"

exit 1
