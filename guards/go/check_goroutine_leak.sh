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

# --- Baseline/diff 过滤：只报告新增行上的问题（pre-commit 或 --baseline 模式）---
_LINEMAP=""
_IN_DIFF_MODE=false
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] || [[ -n "${BASELINE_COMMIT:-}" ]]; then
  _IN_DIFF_MODE=true
  _LINEMAP=$(create_tmpfile)
  vg_build_diff_linemap "$_LINEMAP" '\.go$'
fi

# _in_diff_mode: 检测是否处于 diff 模式，不依赖 linemap 非空。
# 仅删除行时 linemap 为空，此时应静默通过而非回退到全量扫描。
_in_diff_mode() {
  [[ "$_IN_DIFF_MODE" == true ]]
}

list_go_files "${TARGET_DIR}" \
  | { grep -vE '(_test\.go$|/vendor/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        # 检测 go func() 启动，但排除有退出机制的 goroutine
        while IFS= read -r match; do
          [[ -z "$match" ]] && continue
          LINE_NUM=$(echo "$match" | cut -d: -f1)
          # Baseline 过滤：只报告 goroutine 启动行本身是新增的情况
          if _in_diff_mode; then
            grep -qxF "${f}:${LINE_NUM}" "$_LINEMAP" 2>/dev/null || continue
          fi
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
        while IFS= read -r match; do
          [[ -z "$match" ]] && continue
          LINE_NUM=$(echo "$match" | cut -d: -f1)
          # Baseline 过滤：只报告新增的 for{} 行
          if _in_diff_mode; then
            grep -qxF "${f}:${LINE_NUM}" "$_LINEMAP" 2>/dev/null || continue
          fi
          echo "${f}:${match}"
        done < <(grep -nE '^\s*for\s*\{' "${f}" 2>/dev/null || true)
      fi
    done \
  | awk '{ print "[GO-02/loop] " $0 }' \
  >> "${TMPFILE}" || true

apply_suppression_filter "${TMPFILE}"
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
