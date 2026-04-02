#!/usr/bin/env bash
# VibeGuard Go Guard: Detecting goroutine leak risks (GO-02)
#
# Scan the Go code for goroutines without exit mechanism.
# Usage:
#   bash check_goroutine_leak.sh [target_dir]
#   bash check_goroutine_leak.sh --strict [target_dir]
#
#Detection mode:
# - There is no select/context/return/break/ticker in go func()
# - for {} There is no exit condition in the infinite loop
#
#Exclude:
# - *_test.go test file
# - vendor/ directory

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

# --- Baseline/diff filtering: only report problems on new lines (pre-commit or --baseline mode) ---
_LINEMAP=""
_LINEMAP_DELETED=""
_IN_DIFF_MODE=false
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] || [[ -n "${BASELINE_COMMIT:-}" ]]; then
  _IN_DIFF_MODE=true
  _LINEMAP=$(create_tmpfile)
  _LINEMAP_DELETED=$(create_tmpfile)
  vg_build_diff_linemap "$_LINEMAP" '\.go$' "$_LINEMAP_DELETED"
fi

# _in_diff_mode: Check whether it is in diff mode, does not rely on linemap being non-empty.
# When only deleting lines, the linemap is empty. In this case, it should pass silently instead of falling back to full scan.
_in_diff_mode() {
  [[ "$_IN_DIFF_MODE" == true ]]
}

list_go_files "${TARGET_DIR}" \
  | { grep -vE '(_test\.go$|/vendor/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        # Detect go func() startup, but exclude goroutine with exit mechanism
        while IFS= read -r match; do
          [[ -z "$match" ]] && continue
          LINE_NUM=$(echo "$match" | cut -d: -f1)
          # Baseline filtering: report if the goroutine startup line is new or the exit mechanism is deleted
          if _in_diff_mode; then
            if ! grep -qxF "${f}:${LINE_NUM}" "$_LINEMAP" 2>/dev/null; then
              _body_del=false
              if [[ -s "$_LINEMAP_DELETED" ]]; then
                while IFS= read -r _dl; do
                  case "$_dl" in
                    "${f}:"*)
                      _dl_num="${_dl#"${f}:"}"
                      if [[ "$_dl_num" -ge "$LINE_NUM" ]] && [[ "$_dl_num" -le "$((LINE_NUM+20))" ]]; then
                        _body_del=true; break
                      fi ;;
                  esac
                done < "$_LINEMAP_DELETED"
              fi
              [[ "$_body_del" == true ]] || continue
            fi
          fi
          # Read the last 20 lines of goroutine and check if there is an exit mechanism
          HAS_EXIT=$(sed -n "${LINE_NUM},$((LINE_NUM+20))p" "${f}" 2>/dev/null \
            | grep -cE '(ctx\.Done|context\.WithCancel|wg\.(Add|Done|Wait)|errgroup|<-done|<-quit|<-stop|time\.After|ticker)' 2>/dev/null || true)
          if [[ "${HAS_EXIT:-0}" -eq 0 ]]; then
            echo "${f}:${match}"
          fi
        done < <(grep -nE '^\s*go\s+(func\s*\(|[a-zA-Z])' "${f}" 2>/dev/null || true)
      fi
    done \
  | awk '{ print "[GO-02] " $0 }' \
  > "${TMPFILE}" || true

# Round 2: Detect for {} or for { infinite loop (high risk)
list_go_files "${TARGET_DIR}" \
  | { grep -vE '(_test\.go$|/vendor/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        while IFS= read -r match; do
          [[ -z "$match" ]] && continue
          LINE_NUM=$(echo "$match" | cut -d: -f1)
          # Baseline filtering: report if the for{} line is new or the exit mechanism is deleted
          if _in_diff_mode; then
            if ! grep -qxF "${f}:${LINE_NUM}" "$_LINEMAP" 2>/dev/null; then
              _body_del=false
              if [[ -s "$_LINEMAP_DELETED" ]]; then
                while IFS= read -r _dl; do
                  case "$_dl" in
                    "${f}:"*)
                      _dl_num="${_dl#"${f}:"}"
                      if [[ "$_dl_num" -ge "$LINE_NUM" ]] && [[ "$_dl_num" -le "$((LINE_NUM+20))" ]]; then
                        _body_del=true; break
                      fi ;;
                  esac
                done < "$_LINEMAP_DELETED"
              fi
              [[ "$_body_del" == true ]] || continue
            fi
          fi
          echo "${f}:${match}"
        done < <(grep -nE '^\s*for\s*\{' "${f}" 2>/dev/null || true)
      fi
    done \
  | awk '{ print "[GO-02/loop] " $0 }' \
  >> "${TMPFILE}" || true

apply_suppression_filter "${TMPFILE}"
cat "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

echo ""
if [[ ${FOUND} -eq 0 ]]; then
  echo "No goroutine leak risks found."
else
  echo "Found ${FOUND} goroutine launch/infinite loop site(s) to review."
  echo ""
  echo "Repair method:"
  echo "1. Pass in context.Context and exit through <-ctx.Done()"
  echo "2. Use errgroup.Group to manage goroutine life cycle"
  echo "3. The for {} loop must have select + exit branch"
  echo "4. Make sure each go func() has a clear exit path"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
