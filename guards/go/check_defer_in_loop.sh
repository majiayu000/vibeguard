#!/usr/bin/env bash
# VibeGuard Go Guard: 检测循环内 defer (GO-08)
#
# defer 在循环内不会在每次迭代结束时执行，而是在函数返回时执行。
# 这会导致资源泄漏（文件句柄、数据库连接等在循环结束前不会释放）。
#
# 用法:
#   bash check_defer_in_loop.sh [target_dir]
#   bash check_defer_in_loop.sh --strict [target_dir]
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
      # Flag any new defer lines added inside what looks like a loop context
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "[GO-08] ${f}: ${line}"
      done < <(echo "${DIFF_LINES}" | grep -E '^\+\s*defer\s' || true)
    done <<< "${STAGED_GO}"
  fi > "${TMPFILE}" || true
else
  # Full-file scan mode: use awk to detect defer inside for loops
  list_go_files "${TARGET_DIR}" \
    | { grep -vE '(_test\.go$|/vendor/)' || true; } \
    | while IFS= read -r f; do
        if [[ -f "${f}" ]]; then
          awk '
            /^\s*for\s/ { in_loop++; loop_depth++ }
            /\{/ { if (in_loop) brace_depth++ }
            /\}/ { if (in_loop) { brace_depth--; if (brace_depth <= 0) { in_loop=0; loop_depth--; brace_depth=0 } } }
            /^\s*defer\s/ && in_loop > 0 {
              printf "[GO-08] %s:%d %s\n", FILENAME, NR, $0
            }
          ' "${f}" 2>/dev/null || true
        fi
      done \
    > "${TMPFILE}" || true
fi

cat "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

echo ""
if [[ ${FOUND} -eq 0 ]]; then
  echo "No defer-in-loop issues found."
else
  echo "Found ${FOUND} defer-in-loop issue(s)."
  echo ""
  echo "修复方法："
  echo "  1. 将 defer 所在逻辑提取为独立函数："
  echo "     for _, item := range items {"
  echo "         if err := processItem(item); err != nil { ... }"
  echo "     }"
  echo "     func processItem(item Item) error {"
  echo "         f, err := os.Open(item.Path)"
  echo "         if err != nil { return err }"
  echo "         defer f.Close()  // 在函数结束时正确释放"
  echo "         ..."
  echo "     }"
  echo "  2. 手动在每次迭代末尾关闭资源（不推荐，容易遗漏）"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
