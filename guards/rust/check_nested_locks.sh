#!/usr/bin/env bash
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

source "$(dirname "$0")/common.sh"
eval "$(parse_guard_args "$@")"
TMPFILE=$(create_tmpfile)

# 查找包含锁获取的文件（排除 tests/，逐文件处理兼容空格路径）
list_rs_files "${TARGET_DIR}" \
  | { grep -v '/tests/' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        grep -lE '\.(read|write|lock)[[:space:]]*\(' "${f}" 2>/dev/null || true
      fi
    done \
| while IFS= read -r file; do
  awk '
    /^[[:space:]]*(pub[[:space:]]+)?(async[[:space:]]+)?fn[[:space:]]+/ {
      func_name = $0
      sub(/.*fn[[:space:]]+/, "", func_name)
      sub(/\(.*/, "", func_name)
      lock_count = 0
      brace_depth = 0
      func_line = NR
    }
    /{/ { brace_depth += gsub(/{/, "{") }
    /}/ { brace_depth -= gsub(/}/, "}") }
    /\.(read|write|lock)[[:space:]]*\(/ {
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
  echo ""
  echo "修复方法："
  echo "  1. 合并多个锁到单个 RwLock<CombinedState>（消除嵌套）"
  echo "  2. 如必须多锁，统一获取顺序（如按字母序）防止 ABBA 死锁"
  echo "  3. 缩小锁作用域：let value = lock.read().clone(); drop(lock); 再处理"
  echo "  4. 使用 try_lock() / try_read() 避免无限等待"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
