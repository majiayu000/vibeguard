#!/usr/bin/env bash
# VibeGuard CI: 验证所有守卫脚本可执行且语法正确
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
errors=0

echo "Validating guard scripts..."

# 检查 Rust 守卫
for script in "${REPO_DIR}"/guards/rust/*.sh; do
  [[ -f "$script" ]] || continue
  name=$(basename "$script")

  if [[ ! -x "$script" ]]; then
    echo "FAIL: ${name} is not executable"
    ((errors++))
  fi

  if ! bash -n "$script" 2>/dev/null; then
    echo "FAIL: ${name} has syntax errors"
    ((errors++))
  else
    echo "OK: ${name}"
  fi
done

# 检查 Python 守卫
for script in "${REPO_DIR}"/guards/python/*.py; do
  [[ -f "$script" ]] || continue
  name=$(basename "$script")

  if ! python3 -m py_compile "$script" 2>/dev/null; then
    echo "FAIL: ${name} has syntax errors"
    ((errors++))
  else
    echo "OK: ${name}"
  fi
done

echo
if [[ ${errors} -eq 0 ]]; then
  echo "All guard scripts valid."
else
  echo "FAILED: ${errors} errors found."
  exit 1
fi
