#!/usr/bin/env bash
# VibeGuard Rust Guard: 检测嵌套锁获取 (RS-01)
#
# 检测同一函数内在持有一个锁 guard 的同时获取另一个锁的模式。
# 仅当两次 lock/read/write 调用在同一 brace depth（未被 {} 块分隔）
# 时才报告，排除顺序获取（先获取再释放再获取）的安全模式。
#
# Pre-commit 模式: 只检查 staged 文件中的新增行
# Standalone 模式: 全量扫描
#
# 用法:
#   bash check_nested_locks.sh [target_dir]
#   bash check_nested_locks.sh --strict [target_dir]

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

# Pre-commit 模式：只扫 staged diff 新增行
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
  STAGED_RS=$(grep '\.rs$' "${VIBEGUARD_STAGED_FILES}" \
    | { grep -vE "${VIBEGUARD_EXCLUDE_PATHS}" || true; } \
    | { grep -vE "${VIBEGUARD_TEST_FILE_PATTERN}" || true; })

  if [[ -n "${STAGED_RS}" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" || ! -f "$f" ]] && continue
      # Track actual line numbers from @@ hunk headers so suppression can work
      git diff --cached -U0 -- "${f}" 2>/dev/null \
        | awk -v file="${f}" '
          /^\+\+\+/ { next }
          /^@@ / {
            match($0, /\+[0-9]+/)
            cur_line = substr($0, RSTART+1, RLENGTH-1) + 0
            next
          }
          /^-/ { next }
          /^\+/ {
            content = substr($0, 2)
            if (content ~ /\.(read|write|lock)[[:space:]]*\(/) {
              lock_count++
              if (lock_count == 1) first_line = cur_line
              if (lock_count == 2) second_line = cur_line
            }
            cur_line++
          }
          END {
            if (lock_count > 2) {
              report_line = (second_line > 0) ? second_line : first_line
              printf "[RS-01] %s:%d %d lock acquisitions in staged diff (review manually)\n", file, report_line, lock_count
            }
          }
        '
    done <<< "${STAGED_RS}"
  fi > "${TMPFILE}" || true

# Standalone 模式：全量扫描，改进的嵌套检测
else
  list_rs_prod_files "${TARGET_DIR}" \
    | while IFS= read -r f; do
        if [[ -f "${f}" ]]; then
          grep -lE '\.(read|write|lock)[[:space:]]*\(' "${f}" 2>/dev/null || true
        fi
      done \
  | while IFS= read -r file; do
    # 改进的 awk: 追踪 block scope，只在同一 scope 内多次获取锁时报告。
    # 当遇到 {} 块边界时重置当前 scope 的锁计数。
    # 排除 .read().await 后跟 } (scope drop) 再跟新 .read() 的模式。
    awk '
      /^[[:space:]]*(pub[[:space:]]+)?(async[[:space:]]+)?fn[[:space:]]+/ {
        func_name = $0
        sub(/.*fn[[:space:]]+/, "", func_name)
        sub(/\(.*/, "", func_name)
        lock_count = 0
        active_locks = 0
        max_concurrent = 0
        func_line = NR
        first_bad_line = 0
        brace_depth = 0
      }
      /{/ {
        n = gsub(/{/, "{")
        brace_depth += n
      }
      /}/ {
        n = gsub(/}/, "}")
        brace_depth -= n
        # Closing brace may drop a lock guard — reduce active count
        if (active_locks > 0) active_locks--
      }
      /\.(read|write|lock)[[:space:]]*\(/ {
        lock_count++
        active_locks++
        if (active_locks > max_concurrent) max_concurrent = active_locks
        # Record the line where concurrent nesting first occurs (second concurrent lock)
        if (active_locks > 1 && first_bad_line == 0) first_bad_line = NR
      }
      # .clone() after lock typically means extracting value and dropping guard
      /\.clone\(\)/ {
        if (active_locks > 0) active_locks--
      }
      brace_depth == 0 && func_name != "" {
        if (max_concurrent > 1) {
          report_line = (first_bad_line > 0) ? first_bad_line : func_line
          printf "[RS-01] %s:%d fn %s — %d concurrent lock acquisitions (of %d total)\n", FILENAME, report_line, func_name, max_concurrent, lock_count
        }
        func_name = ""
        lock_count = 0
        active_locks = 0
        max_concurrent = 0
        first_bad_line = 0
      }
    ' "${file}"
  done > "${TMPFILE}"
fi

apply_suppression_filter "${TMPFILE}"
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
