#!/usr/bin/env bash
# VibeGuard Go Guard: detect defer inside loop (GO-08)
#
# defer within a loop is not executed at the end of each iteration, but when the function returns.
# This can lead to resource leaks (file handles, database connections, etc. are not released until the end of the loop).
#
# Usage:
#   bash check_defer_in_loop.sh [target_dir]
#   bash check_defer_in_loop.sh --strict [target_dir]
#
#Exclude:
# - *_test.go test file
# - vendor/ directory

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

# --- Baseline/diff filtering: only report problems on new lines (pre-commit or --baseline mode) ---
_LINEMAP=""
_IN_DIFF_MODE=false
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] || [[ -n "${BASELINE_COMMIT:-}" ]]; then
  _IN_DIFF_MODE=true
  _LINEMAP=$(create_tmpfile)
  vg_build_diff_linemap "$_LINEMAP" '\.go$'
fi

# Use awk to detect the defer in the for loop, and then perform linemap filtering on the results
# Output format (tab separated): [GO-08] filepath\tdefer_linenum\tfor_linenum\tcontent
_AWK_RAW=$(create_tmpfile)
list_go_files "${TARGET_DIR}" \
  | { grep -vE '(_test\.go$|/vendor/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        awk '
          BEGIN { total_depth=0; loop_depth=0; flit_depth=0 }
          {
            line = $0

            # 1. Detect for loop start (POSIX [[:space:]] for BSD awk compat)
            if (match(line, /^[[:space:]]*for([[:space:]]|$)/)) {
              loop_depth++
              loop_starts[loop_depth] = NR
              loop_brace_base[loop_depth] = total_depth
            }

            # 2. Detect func literal inside loop (exclude defer-prefixed lines)
            #    go func() { ... } / func() { ... } -> safe scope for defer
            #    defer func() { ... }() -> defer is at loop level, NOT safe
            is_flit = 0
            if (loop_depth > 0 && !match(line, /^[[:space:]]*defer[[:space:]]/)) {
              if (match(line, /[^[:alnum:]_]func[[:space:]]*\(/) || match(line, /^[[:space:]]*func[[:space:]]*\(/)) {
                is_flit = 1
              }
            }
            if (is_flit) {
              flit_depth++
              flit_base[flit_depth] = total_depth
            }

            # 3. Detect defer in loop but NOT inside func literal
            if (match(line, /^[[:space:]]*defer[[:space:]]/) && loop_depth > 0 && flit_depth == 0) {
              printf "[GO-08] %s\t%d\t%d\t%s\n", FILENAME, NR, loop_starts[loop_depth], line
            }

            # 4. Count braces via gsub (handles multiple { } per line)
            tmp = line; opens = gsub(/\{/, "", tmp)
            tmp = line; closes = gsub(/\}/, "", tmp)
            total_depth += opens - closes

            # 5. Exit func literals whose scope has closed
            while (flit_depth > 0 && total_depth <= flit_base[flit_depth]) {
              flit_depth--
            }

            # 6. Exit loops whose scope has closed
            while (loop_depth > 0 && total_depth <= loop_brace_base[loop_depth]) {
              loop_depth--
            }
          }
        ' "${f}" 2>/dev/null || true
      fi
    done \
  > "${_AWK_RAW}" || true

# Linemap filtering: extract file:linenum and only keep new lines
# When _IN_DIFF_MODE=true and linemap is empty (only delete lines), pass silently instead of full scan.
# Check whether the defer line or the starting line of the for loop is a new line (capture the "existing defer is wrapped by a new for" situation).
if [[ "$_IN_DIFF_MODE" == true ]]; then
  while IFS= read -r result_line; do
    [[ -z "$result_line" ]] && continue
    stripped="${result_line#\[GO-08\] }"
    filepath=$(printf '%s' "$stripped" | cut -f1)
    defer_linenum=$(printf '%s' "$stripped" | cut -f2)
    for_linenum=$(printf '%s' "$stripped" | cut -f3)
    content=$(printf '%s' "$stripped" | cut -f4-)
    if [[ -n "$defer_linenum" ]] && [[ -n "$_LINEMAP" ]] && {
      grep -qxF "${filepath}:${defer_linenum}" "$_LINEMAP" 2>/dev/null || \
      grep -qxF "${filepath}:${for_linenum}" "$_LINEMAP" 2>/dev/null
    }; then
      echo "[GO-08] ${filepath}:${defer_linenum} ${content}"
    fi
  done < "${_AWK_RAW}" > "${TMPFILE}" || true
else
  while IFS= read -r result_line; do
    [[ -z "$result_line" ]] && continue
    stripped="${result_line#\[GO-08\] }"
    filepath=$(printf '%s' "$stripped" | cut -f1)
    defer_linenum=$(printf '%s' "$stripped" | cut -f2)
    content=$(printf '%s' "$stripped" | cut -f4-)
    echo "[GO-08] ${filepath}:${defer_linenum} ${content}"
  done < "${_AWK_RAW}" > "${TMPFILE}" || true
fi

apply_suppression_filter "${TMPFILE}"
cat "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

echo ""
if [[ ${FOUND} -eq 0 ]]; then
  echo "No defer-in-loop issues found."
else
  echo "Found ${FOUND} defer-in-loop issue(s)."
  echo ""
  echo "Repair method:"
  echo " 1. Extract the logic of defer into an independent function: "
  echo "     for _, item := range items {"
  echo "         if err := processItem(item); err != nil { ... }"
  echo "     }"
  echo "     func processItem(item Item) error {"
  echo "         f, err := os.Open(item.Path)"
  echo "         if err != nil { return err }"
  echo " defer f.Close() // Correctly released at the end of the function"
  echo "         ..."
  echo "     }"
  echo "2. Manually close resources at the end of each iteration (not recommended, easy to miss)"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
