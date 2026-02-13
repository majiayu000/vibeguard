#!/usr/bin/env bash
set -euo pipefail

# VibeGuard Rust Guard: 检测嵌套锁获取 (RS-01)
#
# 扫描同一函数内多次调用 .lock()/.read()/.write() 的模式，
# 这可能导致 ABBA 死锁。
#
# 用法:
#   bash check_nested_locks.sh [target_dir]
#   bash check_nested_locks.sh --strict [target_dir]
#
# 排除: tests/ 目录

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

# 查找包含锁获取的文件（排除 tests/，逐文件处理兼容空格路径）
list_rs_files "${TARGET_DIR}" \
  | grep -v '/tests/' \
  | while IFS= read -r f; do
      [[ -f "${f}" ]] && grep -lE '\.(read|write|lock)\s*\(' "${f}" 2>/dev/null
    done \
| while IFS= read -r file; do
  awk '
    /^\s*(pub\s+)?(async\s+)?fn\s+/ {
      func_name = $0
      sub(/.*fn\s+/, "", func_name)
      sub(/\(.*/, "", func_name)
      lock_count = 0
      brace_depth = 0
      func_line = NR
    }
    /{/ { brace_depth += gsub(/{/, "{") }
    /}/ { brace_depth -= gsub(/}/, "}") }
    /\.(read|write|lock)\s*\(/ {
      lock_count++
    }
    brace_depth == 0 && func_name != "" && lock_count > 2 {
      printf "[RS-01] %s:%d fn %s — %d lock acquisitions in single function\n", FILENAME, func_line, func_name, lock_count
      func_name = ""
      lock_count = 0
    }
  ' "${file}"
done > "${TMPFILE}"

cat "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

echo ""
if [[ "${FOUND}" -eq 0 ]]; then
  echo "No nested lock patterns detected."
else
  echo "Found ${FOUND} potential nested lock pattern(s)."
  echo "Review each to ensure consistent lock ordering or reduce lock scope."
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
