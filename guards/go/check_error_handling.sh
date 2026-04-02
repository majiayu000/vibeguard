#!/usr/bin/env bash
# VibeGuard Go Guard: Detect unchecked error return values (GO-01)
#
# Use ast-grep AST level scanning to accurately identify the `_ = func()` assignment statement.
# ast-grep automatically distinguishes the code structure and will not falsely report the _ variable in the for range clause.
#
# Usage:
#   bash check_error_handling.sh [target_dir]
#   bash check_error_handling.sh --strict [target_dir]
#
#Exclude:
# - *_test.go test file
# - vendor/ directory

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"

# --- Baseline/diff filtering: only report problems on new lines (pre-commit or --baseline mode) ---
_LINEMAP=""
_IN_DIFF_MODE=false
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] || [[ -n "${BASELINE_COMMIT:-}" ]]; then
  _IN_DIFF_MODE=true
  _LINEMAP=$(create_tmpfile)
  vg_build_diff_linemap "$_LINEMAP" '\.go$'
fi

_USE_GREP_FALLBACK=false

if command -v ast-grep >/dev/null 2>&1; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[GO-01] WARN: python3 is not available, use grep fallback" >&2
    _USE_GREP_FALLBACK=true
  else
    # staged mode: only scan staged Go files to avoid full warehouse scanning blocking irrelevant submissions
    if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
      mapfile -t _ASG_TARGETS < <(grep -E '\.go$' "${VIBEGUARD_STAGED_FILES}" 2>/dev/null || true)
    else
      _ASG_TARGETS=("${TARGET_DIR}")
    fi

    if [[ ${#_ASG_TARGETS[@]} -gt 0 ]]; then
      _ASG_TMPOUT=$(create_tmpfile)
      if ast-grep scan \
          --rule "${RULES_DIR}/go-01-error.yml" \
          --json \
          "${_ASG_TARGETS[@]}" > "${_ASG_TMPOUT}"; then
        VG_DIFF_LINEMAP="$_LINEMAP" VG_IN_DIFF_MODE="$_IN_DIFF_MODE" python3 -c '
import json, sys, re, os

TEST_PATH = re.compile(r"(_test\.go$|(^|/)vendor/)")
linemap_path = os.environ.get("VG_DIFF_LINEMAP", "")
in_diff_mode = os.environ.get("VG_IN_DIFF_MODE", "false") == "true"
added_set = set()
if linemap_path and os.path.isfile(linemap_path):
    with open(linemap_path) as lm:
        for entry in lm:
            added_set.add(entry.strip())

data = sys.stdin.read().strip()
if not data:
    sys.exit(0)
try:
    matches = json.loads(data)
except Exception as e:
    print("[GO-01] WARN: ast-grep JSON parsing failed: " + str(e), file=sys.stderr)
    sys.exit(1)
for m in matches:
    f = m.get("file", "")
    if TEST_PATH.search(f):
        continue
    line = m.get("range", {}).get("start", {}).get("line", 0) + 1
    # Baseline filtering: only report problems on new lines in diff.
    # Use in_diff_mode instead of added_set non-empty to determine the diff mode.
    # Avoid falling back to full scan when added_set is empty when only deleting rows.
    if in_diff_mode and (f + ":" + str(line)) not in added_set:
        continue
    msg = m.get("message", "error return value is discarded")
    print("[GO-01] " + f + ":" + str(line) + " " + msg)
' < "${_ASG_TMPOUT}" > "${TMPFILE}" || {
          echo "[GO-01] WARN: python3 processing failed, use grep fallback" >&2
          _USE_GREP_FALLBACK=true
        }
      else
        echo "[GO-01] WARN: ast-grep scan failed (the rule file may be missing), use grep fallback" >&2
        _USE_GREP_FALLBACK=true
      fi
    fi
  fi
else
  _USE_GREP_FALLBACK=true
fi

if [[ "$_USE_GREP_FALLBACK" == true ]]; then
  list_go_files "${TARGET_DIR}" \
    | { grep -vE '(_test\.go$|/vendor/)' || true; } \
    | while IFS= read -r f; do
        if [[ -f "${f}" ]]; then
          grep -nE '^\s*_\s*(,\s*_)?\s*[:=]+' "${f}" 2>/dev/null \
            | grep -vE 'for\s+.*range' \
            | grep -vE ',\s*(ok|found|exists)\s*:?=' \
            | while IFS= read -r hit; do
                LINE_NUM=$(echo "$hit" | cut -d: -f1)
                # Baseline filtering: only report problems on new lines
                if [[ "$_IN_DIFF_MODE" == true ]]; then
                  grep -qxF "${f}:${LINE_NUM}" "$_LINEMAP" 2>/dev/null || continue
                fi
                echo "${f}:${hit}"
              done
        fi
      done \
    | grep -v '^\s*//' \
    | awk '!/^[[:space:]]*\/\// { print "[GO-01] " $0 }' \
    > "${TMPFILE}" || true
fi

apply_suppression_filter "${TMPFILE}"
sed 's/^\[GO-01\] /[GO-01] [auto-fix] [this-line] OBSERVATION: /' "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

echo ""
if [[ ${FOUND} -eq 0 ]]; then
  echo "No unchecked error returns found."
else
  echo "Found ${FOUND} unchecked error return(s)."
  echo ""
  echo "SCOPE: this-line only — do not modify function signatures or upstream callers"
  echo "ACTION: REVIEW"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
