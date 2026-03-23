#!/usr/bin/env bash
# VibeGuard Go Guard: 检测 goroutine 泄漏风险 (GO-02)
#
# 扫描 Go 代码中无退出机制的 goroutine。
# 用法:
#   bash check_goroutine_leak.sh [target_dir]
#   bash check_goroutine_leak.sh --strict [target_dir]
#
# 检测模式:
#   - go func() 内无 select/context/return/break/ticker
#   - for {} 无限循环内无退出条件
#
# 排除:
#   - *_test.go 测试文件
#   - vendor/ 目录

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

# Pre-commit diff-only mode: only check lines added in staged diff
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
  STAGED_GO=$(grep -E '\.go$' "${VIBEGUARD_STAGED_FILES}" \
    | grep -vE '(_test\.go$|/vendor/)' || true)
  if [[ -n "${STAGED_GO}" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" || ! -f "$f" ]] && continue
      DIFF_LINES=$(git diff --cached -U0 -- "${f}" 2>/dev/null | grep '^+' | grep -v '^+++' || true)
      [[ -z "${DIFF_LINES}" ]] && continue

      # Check for new goroutine launches in diff
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "[GO-02] ${f}: ${line}"
      done < <(echo "${DIFF_LINES}" | grep -E '^\+\s*go\s+(func\s*\(|[a-zA-Z])' || true)

      # Check for new bare infinite loops in diff
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "[GO-02/loop] ${f}: ${line}"
      done < <(echo "${DIFF_LINES}" | grep -E '^\+\s*for\s*\{' || true)

    done <<< "${STAGED_GO}"
  fi > "${TMPFILE}" || true
else
  # Full-file scan mode
  list_go_files "${TARGET_DIR}" \
    | { grep -vE '(_test\.go$|/vendor/)' || true; } \
    | while IFS= read -r f; do
        if [[ -f "${f}" ]]; then
          # 检测 go func() 启动，但排除有退出机制的 goroutine
          while IFS= read -r match; do
            [[ -z "$match" ]] && continue
            LINE_NUM=$(echo "$match" | cut -d: -f1)
            # 读取 goroutine 后 20 行，检查是否有退出机制
            HAS_EXIT=$(sed -n "${LINE_NUM},$((LINE_NUM+20))p" "${f}" 2>/dev/null \
              | grep -cE '(ctx\.Done|context\.WithCancel|wg\.(Add|Done|Wait)|errgroup|<-done|<-quit|<-stop|time\.After|ticker)' 2>/dev/null || true)
            if [[ "${HAS_EXIT:-0}" -eq 0 ]]; then
              echo "${f}:${match}"
            fi
          done < <(grep -nE '^\s*go\s+(func\s*\(|[a-zA-Z])' "${f}" 2>/dev/null || true)
        fi
      done \
    | awk '{ print "[GO-02] " $0 }' \
    > "${TMPFILE}" || true

  # 第二轮：检测 for {} 或 for { 无限循环（高风险）
  list_go_files "${TARGET_DIR}" \
    | { grep -vE '(_test\.go$|/vendor/)' || true; } \
    | while IFS= read -r f; do
        if [[ -f "${f}" ]]; then
          grep -nE '^\s*for\s*\{' "${f}" 2>/dev/null \
            | sed "s|^|${f}:|" || true
        fi
      done \
    | awk '{ print "[GO-02/loop] " $0 }' \
    >> "${TMPFILE}" || true
fi

cat "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

echo ""
if [[ ${FOUND} -eq 0 ]]; then
  echo "No goroutine leak risks found."
else
  echo "Found ${FOUND} goroutine launch/infinite loop site(s) to review."
  echo ""
  echo "修复方法："
  echo "  1. 传入 context.Context，通过 <-ctx.Done() 退出"
  echo "  2. 使用 errgroup.Group 管理 goroutine 生命周期"
  echo "  3. for {} 循环必须有 select + 退出分支"
  echo "  4. 确保每个 go func() 都有明确的退出路径"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
