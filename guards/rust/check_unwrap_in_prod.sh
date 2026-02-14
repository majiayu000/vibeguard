#!/usr/bin/env bash
set -euo pipefail

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

TARGET_DIR="${1:-.}"
STRICT=false

if [[ "${1:-}" == "--strict" ]]; then
  STRICT=true
  TARGET_DIR="${2:-.}"
elif [[ "${2:-}" == "--strict" ]]; then
  STRICT=true
fi

# 列出 .rs 源文件（优先 git ls-files，非 git 仓库降级 find）
list_rs_files() {
  local dir="$1"
  if git -C "${dir}" rev-parse --is-inside-work-tree &>/dev/null; then
    git -C "${dir}" ls-files '*.rs' | while IFS= read -r f; do echo "${dir}/${f}"; done
  else
    find "${dir}" -name '*.rs' -not -path '*/target/*' -not -path '*/.git/*'
  fi
}

TMPFILE=$(mktemp)
trap 'rm -f "${TMPFILE}"' EXIT

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
  echo "Consider using ? operator, unwrap_or_else(), or match instead."
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
