#!/usr/bin/env bash
# VibeGuard Rust Guard: Detect nested lock acquisitions (RS-01)
#
# Detect the pattern of acquiring another lock while holding one lock guard in the same function.
# Only if two lock/read/write calls are at the same brace depth (not separated by {} blocks)
# Report only when required, excluding the safe mode of sequential acquisition (first acquire, then release, then acquire).
#
# Pre-commit mode: only check new lines in staged files
# Standalone mode: full scan
#
# Usage:
#   bash check_nested_locks.sh [target_dir]
#   bash check_nested_locks.sh --strict [target_dir]

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

# Pre-commit mode: only scan new lines in staged diff
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
  if ! grep -q '\.rs$' "${VIBEGUARD_STAGED_FILES}" 2>/dev/null; then
    STAGED_RS=""
  else
    STAGED_RS=$(grep '\.rs$' "${VIBEGUARD_STAGED_FILES}" \
      | { grep -vE "${VIBEGUARD_EXCLUDE_PATHS}" || true; } \
      | { grep -vE "${VIBEGUARD_TEST_FILE_PATTERN}" || true; })
  fi

  if [[ -n "${STAGED_RS}" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" || ! -f "$f" ]] && continue
      diff_out=$(git diff --cached -U0 -- "${f}" 2>/dev/null)
      count=$(printf '%s\n' "$diff_out" | grep '^+' | grep -v '^+++' \
        | grep -cE '\.(read|write|lock)[[:space:]]*\(') || count=0
      if [[ "$count" -gt 2 ]]; then
        # Find first new-file line number of a lock acquisition so
        # apply_suppression_filter can match vibeguard-disable-next-line.
        first_line=$(printf '%s\n' "$diff_out" | awk '
          /^@@ / {
            tmp = $0
            sub(/^.*\+/, "", tmp)
            sub(/[^0-9].*/, "", tmp)
            cur = tmp + 0 - 1
          }
          /^\+[^+]/ {
            cur++
            if ($0 ~ /\.(read|write|lock)[[:space:]]*\(/) {
              print cur; exit
            }
          }
        ')
        [[ -z "$first_line" ]] && first_line=1
        echo "[RS-01] ${f}:${first_line}: ${count} lock acquisitions in staged diff (review manually)"
      fi
    done <<< "${STAGED_RS}"
  fi > "${TMPFILE}" || true

# Standalone mode: full scan, improved nesting detection
else
  list_rs_prod_files "${TARGET_DIR}" \
    | while IFS= read -r f; do
        if [[ -f "${f}" ]]; then
          grep -lE '\.(read|write|lock)[[:space:]]*\(' "${f}" 2>/dev/null || true
        fi
      done \
  | while IFS= read -r file; do
    # Improved awk: Track block scope and only report when locks are acquired multiple times in the same scope.
    #Reset the current scope's lock count when encountering a {} block boundary.
    # Exclude the pattern of .read().await followed by } (scope drop) followed by a new .read().
    awk '
      /^[[:space:]]*(pub[[:space:]]+)?(async[[:space:]]+)?fn[[:space:]]+/ {
        func_name = $0
        sub(/.*fn[[:space:]]+/, "", func_name)
        sub(/\(.*/, "", func_name)
        lock_count = 0
        active_locks = 0
        max_concurrent = 0
        func_line = NR
        brace_depth = 0
        lock_idx = 0
        delete lock_depths
      }
      /{/ {
        n = gsub(/{/, "{")
        brace_depth += n
      }
      /\.(read|write|lock)[[:space:]]*\(/ {
        # Count all lock acquisitions on this line using gsub so multiple calls on one
        # line (e.g. the two .lock() calls in self.a.lock().map(|_a| { self.b.lock() }))
        # are each tracked individually.
        _tmp = $0
        gsub(/\/\/.*$/, "", _tmp)        # strip line comments
        gsub(/"[^"]*"/, "", _tmp)        # strip simple string literals
        _n = gsub(/\.(read|write|lock)[[:space:]]*\(/, "", _tmp)
        # Do NOT use next when _n < 1: pattern fired on comment/string only,
        # but the /}/ rule below must still run to keep brace_depth accurate.
        if (_n >= 1) {
          lock_count += _n
          # A chained call like .lock().clone() / .lock().to_string() drops the guard
          # immediately (value extracted, guard never bound to a variable).  Only apply
          # this exemption for known value-extraction methods; closure-passing methods
          # like .lock().map(|g| { ... }) HOLD the guard through the closure body.
          _value_chain = /\.(read|write|lock)[[:space:]]*\([^)]*\)\.(clone|to_owned|to_string|len|is_empty|contains)\(/
          if (!(_value_chain && _n == 1)) {
            for (_k = 0; _k < _n; _k++) {
              lock_depths[lock_idx] = brace_depth
              lock_idx++
              active_locks++
            }
            if (active_locks > max_concurrent) max_concurrent = active_locks
          }
        }
      }
      /}/ {
        n = gsub(/}/, "}")
        brace_depth -= n
        # Release lock guards that went out of scope: their acquisition brace_depth
        # is now greater than the current brace_depth, meaning their block closed.
        # Iterate from newest to oldest lock to release in LIFO order.
        for (i = lock_idx - 1; i >= 0; i--) {
          if (lock_depths[i] > brace_depth) {
            active_locks--
            delete lock_depths[i]
            lock_idx--
          }
        }
      }
      brace_depth == 0 && func_name != "" {
        if (max_concurrent > 1) {
          printf "[RS-01] %s:%d fn %s — %d concurrent lock acquisitions (of %d total)\n", FILENAME, func_line, func_name, max_concurrent, lock_count
        }
        func_name = ""
        lock_count = 0
        active_locks = 0
        max_concurrent = 0
        lock_idx = 0
        delete lock_depths
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
  echo "Repair method:"
  echo " 1. Combine multiple locks into a single RwLock<CombinedState> (eliminate nesting)"
  echo "2. If multiple locks are necessary, unify the acquisition order (such as alphabetical order) to prevent ABBA deadlock"
  echo "3. Reduce the lock scope: let value = lock.read().clone(); drop(lock); and then process"
  echo "4. Use try_lock() / try_read() to avoid infinite waiting"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
