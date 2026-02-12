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

FOUND=0

# 搜索 .unwrap() 和 .expect()，排除安全变体和测试代码
while IFS= read -r line; do
  # 跳过注释行
  if echo "${line}" | grep -qE '^\s*//'; then
    continue
  fi
  # 跳过 unwrap_or 系列（安全的降级）
  if echo "${line}" | grep -qE 'unwrap_or|unwrap_or_else|unwrap_or_default'; then
    continue
  fi
  echo "[RS-03] ${line}"
  ((FOUND++)) || true
done < <(
  grep -rn --include='*.rs' \
    -E '\.(unwrap|expect)\(' \
    "${TARGET_DIR}" \
    | grep -v '/tests/' \
    | grep -v '/test_' \
    | grep -v '_test\.rs:' \
    | grep -v '/examples/' \
    | grep -v 'mod tests' \
    | grep -v '#\[cfg(test)\]' \
    | grep -v 'unwrap_or' \
    | grep -v 'unwrap_or_else' \
    | grep -v 'unwrap_or_default' \
    || true
)

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
