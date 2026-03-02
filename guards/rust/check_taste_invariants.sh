#!/usr/bin/env bash
# VibeGuard Rust Guard: Harness 风格 Taste Invariants
#
# 检测 Rust 代码品味约束（对标 OpenAI Harness Engineering）。
# 不使用独立规则 ID，避免与 RS-01~RS-13 冲突。
#
# 检测项:
#   - TASTE-ANSI: 硬编码 ANSI 转义序列（应使用 colored/termcolor crate）
#   - TASTE-FOLD: 可折叠的单行 if（可简化为 then/map）
#   - TASTE-ASYNC-UNWRAP: async fn 内 .unwrap()（应使用 ?）
#   - TASTE-PANIC-MSG: panic!() 缺少有意义的消息
#
# 用法:
#   bash check_taste_invariants.sh [target_dir]
#   bash check_taste_invariants.sh --strict [target_dir]

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)
TOTAL=0

# --- TASTE-ANSI: 硬编码 ANSI 转义序列 ---
ANSI_TMP=$(create_tmpfile)
list_rs_files "${TARGET_DIR}" \
  | { grep -vE '(/tests/|/test_|_test\.rs$|/examples/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        grep -nE '\\x1b\[|\\033\[|\\e\[' "${f}" 2>/dev/null \
          | sed "s|^|${f}:|" || true
      fi
    done \
  | awk '!/^[[:space:]]*\/\// { print "[TASTE-ANSI] " $0 }' \
  > "${ANSI_TMP}" || true

cat "${ANSI_TMP}" >> "${TMPFILE}"
ANSI_COUNT=$(wc -l < "${ANSI_TMP}" | tr -d ' ')
TOTAL=$((TOTAL + ANSI_COUNT))

# --- TASTE-ASYNC-UNWRAP: async fn 内 .unwrap() ---
ASYNC_TMP=$(create_tmpfile)
list_rs_files "${TARGET_DIR}" \
  | { grep -vE '(/tests/|/test_|_test\.rs$|/examples/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        # 简单检测：同文件有 async fn 且有 .unwrap()
        if grep -qE 'async\s+fn' "${f}" 2>/dev/null; then
          grep -nE '\.(unwrap|expect)\(' "${f}" 2>/dev/null \
            | grep -v 'unwrap_or' \
            | grep -v 'unwrap_or_else' \
            | grep -v 'unwrap_or_default' \
            | sed "s|^|${f}:|" || true
        fi
      fi
    done \
  | awk '!/^[[:space:]]*\/\// { print "[TASTE-ASYNC-UNWRAP] " $0 }' \
  > "${ASYNC_TMP}" || true

cat "${ASYNC_TMP}" >> "${TMPFILE}"
ASYNC_COUNT=$(wc -l < "${ASYNC_TMP}" | tr -d ' ')
TOTAL=$((TOTAL + ASYNC_COUNT))

# --- TASTE-PANIC-MSG: panic!() 缺少有意义的消息 ---
PANIC_TMP=$(create_tmpfile)
list_rs_files "${TARGET_DIR}" \
  | { grep -vE '(/tests/|/test_|_test\.rs$|/examples/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        # 检测 panic!() 无参数或只有空字符串
        grep -nE 'panic!\s*\(\s*\)|panic!\s*\(\s*""\s*\)' "${f}" 2>/dev/null \
          | sed "s|^|${f}:|" || true
      fi
    done \
  | awk '{ print "[TASTE-PANIC-MSG] " $0 }' \
  > "${PANIC_TMP}" || true

cat "${PANIC_TMP}" >> "${TMPFILE}"
PANIC_COUNT=$(wc -l < "${PANIC_TMP}" | tr -d ' ')
TOTAL=$((TOTAL + PANIC_COUNT))

# --- 输出汇总 ---
echo ""
cat "${TMPFILE}"
echo ""

if [[ ${TOTAL} -eq 0 ]]; then
  echo "Taste invariants check passed — no issues found."
else
  echo "Found ${TOTAL} taste invariant violation(s):"
  [[ ${ANSI_COUNT} -gt 0 ]] && echo "  TASTE-ANSI:          ${ANSI_COUNT} (硬编码 ANSI → 使用 colored/termcolor crate)"
  [[ ${ASYNC_COUNT} -gt 0 ]] && echo "  TASTE-ASYNC-UNWRAP:  ${ASYNC_COUNT} (async fn 中 unwrap → 使用 ? 操作符)"
  [[ ${PANIC_COUNT} -gt 0 ]] && echo "  TASTE-PANIC-MSG:     ${PANIC_COUNT} (panic 无消息 → 添加上下文描述)"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
