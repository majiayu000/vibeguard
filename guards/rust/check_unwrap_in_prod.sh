#!/usr/bin/env bash
# VibeGuard Rust Guard: 检测生产代码中的 unwrap()/expect() (RS-03)
#
# 扫描非测试 Rust 代码中的 .unwrap() 和 .expect() 调用。
# 用法:
#   bash check_unwrap_in_prod.sh [target_dir]
#   bash check_unwrap_in_prod.sh --strict [target_dir]  # 有违规则退出码 1
#
# 排除:
#   - tests/ 目录
#   - 文件名包含 test 的文件
#   - unwrap_or / unwrap_or_else / unwrap_or_default（安全的变体）
#   - 注释行

source "$(dirname "$0")/common.sh"
eval "$(parse_guard_args "$@")"
TMPFILE=$(create_tmpfile)

# 搜索 .unwrap() 和 .expect()，逐文件处理兼容空格路径和空输入
list_rs_files "${TARGET_DIR}" \
  | { grep -vE '(/tests/|/test_|_test\.rs$|/examples/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        grep -nE '\.(unwrap|expect)\(' "${f}" 2>/dev/null \
          | sed "s|^|${f}:|" || true
      fi
    done \
  | grep -v 'unwrap_or' \
  | grep -v 'unwrap_or_else' \
  | grep -v 'unwrap_or_default' \
  | grep -v '#\[cfg(test)\]' \
  | grep -v 'mod tests' \
  | awk '!/^[[:space:]]*\/\// { print "[RS-03] " $0 }' \
  > "${TMPFILE}" || true

cat "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

echo ""
if [[ ${FOUND} -eq 0 ]]; then
  echo "No unwrap()/expect() in production code."
else
  echo "Found ${FOUND} unwrap()/expect() call(s) in production code."
  echo ""
  echo "修复方法："
  echo "  1. .unwrap() → .map_err(|e| YourError::from(e))? （向上传播错误）"
  echo "  2. .unwrap() → .unwrap_or_default() （提供默认值）"
  echo "  3. .unwrap() → .unwrap_or_else(|| fallback()) （延迟计算默认值）"
  echo "  4. .expect(\"msg\") → match / if let （自定义处理逻辑）"
  echo "  5. main() 中 → 使用 anyhow::Result<()> 配合 ? 操作符"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
