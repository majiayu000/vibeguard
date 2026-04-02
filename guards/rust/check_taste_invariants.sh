#!/usr/bin/env bash
# VibeGuard Rust Guard: Harness Style Taste Invariants
#
# Detect Rust code taste constraints (benchmarked by OpenAI Harness Engineering).
# Do not use independent rule IDs to avoid conflicts with RS-01~RS-13.
#
# Detection items:
# - TASTE-ANSI: hardcoded ANSI escape sequences (colored/termcolor crate should be used)
# - TASTE-FOLD: Foldable single line if (can be simplified to then/map)
# - TASTE-ASYNC-UNWRAP: .unwrap() inside async fn (should use ?)
# - TASTE-PANIC-MSG: panic!() lacks meaningful message
#
# Usage:
#   bash check_taste_invariants.sh [target_dir]
#   bash check_taste_invariants.sh --strict [target_dir]

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)
TOTAL=0

# --- TASTE-ANSI: Hardcoded ANSI escape sequence ---
ANSI_TMP=$(create_tmpfile)
list_rs_files "${TARGET_DIR}" \
  | { grep -vE '(/tests/|/test_|_test\.rs$|/examples/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        grep -nE '\\x1b\[|\\033\[|\\e\[' "${f}" 2>/dev/null \
          | sed "s|^|${f}:|" || true
      fi
    done \
  | awk '!/^[[:space:]]*\/\// { print "[TASTE-ANSI] " $0 }' \
  > "${ANSI_TMP}" || true

cat "${ANSI_TMP}" >> "${TMPFILE}"
ANSI_COUNT=$(wc -l < "${ANSI_TMP}" | tr -d ' ')
TOTAL=$((TOTAL + ANSI_COUNT))

# --- TASTE-ASYNC-UNWRAP: async fn within .unwrap() ---
# Fix: use awk to track async fn scope so we only flag unwrap() calls that are
# actually inside an async function body, not any unwrap() in a file that happens
# to contain an async fn somewhere else.
ASYNC_TMP=$(create_tmpfile)
list_rs_files "${TARGET_DIR}" \
  | { grep -vE '(/tests/|/test_|_test\.rs$|/examples/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        awk '
          # Detect start of async fn; wait for the opening brace
          /async[[:space:]]+fn[[:space:]]+/ { pending_async = 1; brace_depth = 0; matched_open = 0 }
          # Trait/interface method declarations end with ; and have no body — clear pending
          # so the next real function'"'"'s { is not mistaken for this async fn'"'"'s body.
          pending_async && /;/ && !/{/ { pending_async = 0; next }
          pending_async && /{/ {
            n = split($0, a, "{"); brace_depth += n - 1
            n = split($0, a, "}"); brace_depth -= n - 1
            matched_open = 1
            # Check for unwrap on this same line (single-line async fn or opening-brace
            # on the same line as fn signature), before deciding in_async state.
            if (/\.(unwrap|expect)\(/ && !/unwrap_or/ && !/^[[:space:]]*\/\//)
              print NR ": " $0
            if (brace_depth <= 0) { pending_async = 0; in_async = 0 }
            else in_async = 1
            next
          }
          in_async {
            n = split($0, a, "{"); brace_depth += n - 1
            n = split($0, a, "}"); brace_depth -= n - 1
            if (brace_depth <= 0) { in_async = 0; pending_async = 0 }
            if (/\.(unwrap|expect)\(/ && !/unwrap_or/ && !/^[[:space:]]*\/\//)
              print NR ": " $0
          }
        ' "${f}" | sed "s|^|${f}:|" || true
      fi
    done \
  | awk '{ print "[TASTE-ASYNC-UNWRAP] " $0 }' \
  > "${ASYNC_TMP}" || true

cat "${ASYNC_TMP}" >> "${TMPFILE}"
ASYNC_COUNT=$(wc -l < "${ASYNC_TMP}" | tr -d ' ')
TOTAL=$((TOTAL + ASYNC_COUNT))

# --- TASTE-PANIC-MSG: panic!() lacks meaningful message ---
PANIC_TMP=$(create_tmpfile)
list_rs_files "${TARGET_DIR}" \
  | { grep -vE '(/tests/|/test_|_test\.rs$|/examples/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        # Detect panic!() with no parameters or only empty string
        grep -nE 'panic!\s*\(\s*\)|panic!\s*\(\s*""\s*\)' "${f}" 2>/dev/null \
          | sed "s|^|${f}:|" || true
      fi
    done \
  | awk '{ print "[TASTE-PANIC-MSG] " $0 }' \
  > "${PANIC_TMP}" || true

cat "${PANIC_TMP}" >> "${TMPFILE}"
PANIC_COUNT=$(wc -l < "${PANIC_TMP}" | tr -d ' ')
TOTAL=$((TOTAL + PANIC_COUNT))

# --- Output summary ---
echo ""
cat "${TMPFILE}"
echo ""

if [[ ${TOTAL} -eq 0 ]]; then
  echo "Taste invariants check passed — no issues found."
else
  echo "Found ${TOTAL} taste invariant violation(s):"
  [[ ${ANSI_COUNT} -gt 0 ]] && echo " TASTE-ANSI: ${ANSI_COUNT} (hardcoded ANSI → use colored/termcolor crate)"
  [[ ${ASYNC_COUNT} -gt 0 ]] && echo " TASTE-ASYNC-UNWRAP: ${ASYNC_COUNT} (unwrap → in async fn uses the ? operator)"
  [[ ${PANIC_COUNT} -gt 0 ]] && echo " TASTE-PANIC-MSG: ${PANIC_COUNT} (panic no message → add context description)"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
