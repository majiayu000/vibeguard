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

FOUND=0

# 查找包含多个锁获取的函数
# 策略：找到包含 .read().await 或 .write().await 或 .lock() 的文件
# 然后检查是否同一个函数块内有多于 2 个不同的锁获取
while IFS= read -r file; do
  # 对每个文件，用 awk 检测函数内多次锁获取
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
done < <(
  grep -rl --include='*.rs' \
    -E '\.(read|write|lock)\s*\(' \
    "${TARGET_DIR}" \
    | grep -v '/tests/' \
    || true
) | while IFS= read -r line; do
  echo "${line}"
  ((FOUND++)) || true
done

# 重新计数（管道 subshell 问题）
FOUND=$(
  grep -rl --include='*.rs' \
    -E '\.(read|write|lock)\s*\(' \
    "${TARGET_DIR}" \
    | grep -v '/tests/' \
    | xargs -I{} awk '
    /^\s*(pub\s+)?(async\s+)?fn\s+/ {
      func_name = $0; sub(/.*fn\s+/, "", func_name); sub(/\(.*/, "", func_name)
      lock_count = 0; brace_depth = 0; func_line = NR
    }
    /{/ { brace_depth += gsub(/{/, "{") }
    /}/ { brace_depth -= gsub(/}/, "}") }
    /\.(read|write|lock)\s*\(/ { lock_count++ }
    brace_depth == 0 && func_name != "" && lock_count > 2 {
      printf "[RS-01] %s:%d fn %s — %d lock acquisitions\n", FILENAME, func_line, func_name, lock_count
      func_name = ""; lock_count = 0
    }
  ' {} 2>/dev/null | tee /dev/stderr | wc -l | tr -d ' '
)

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
