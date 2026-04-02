#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-01] any type abuse detection / [TS-02] ts-ignore detection
#
# Use ast-grep to do AST level detection and eliminate comment/string false positives.
# When ast-grep is unavailable, fall back to grep detection.
# Detect `as any`, `: any` (TS-01) and `@ts-ignore`, `@ts-nocheck` (TS-02) in non-test files.
#
# Usage:
#   bash check_any_abuse.sh [--strict] [target_dir]
#
# --strict mode: any violation exits with a non-zero exit code

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"
source "${SCRIPT_DIR}/common.sh"
parse_guard_args "$@"

RESULTS=$(create_tmpfile)

# --- Baseline/diff filtering: only report problems on new lines (pre-commit or --baseline mode) ---
_LINEMAP=""
_IN_DIFF_MODE=false
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] || [[ -n "${BASELINE_COMMIT:-}" ]]; then
  _IN_DIFF_MODE=true
  _LINEMAP=$(create_tmpfile)
  vg_build_diff_linemap "$_LINEMAP" '\.(ts|tsx|js|jsx)$'
fi

# --- TS-01: as any and : any type annotations ---
_USE_GREP_FALLBACK=false

if command -v ast-grep >/dev/null 2>&1; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[TS-01] WARN: python3 is not available, use grep fallback" >&2
    _USE_GREP_FALLBACK=true
  else
    # staged mode: only scan staged TS files to avoid full warehouse scanning blocking irrelevant submissions
    if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
      mapfile -t _ASG_TARGETS < <(grep -E '\.(ts|tsx|js|jsx)$' "${VIBEGUARD_STAGED_FILES}" 2>/dev/null || true)
    else
      _ASG_TARGETS=("${TARGET_DIR}")
    fi

    if [[ ${#_ASG_TARGETS[@]} -gt 0 ]]; then
      _ASG_TMPOUT=$(create_tmpfile)
      if ast-grep scan \
          --rule "${RULES_DIR}/ts-01-any.yml" \
          --json \
          "${_ASG_TARGETS[@]}" > "${_ASG_TMPOUT}"; then
        VG_DIFF_LINEMAP="$_LINEMAP" VG_IN_DIFF_MODE="$_IN_DIFF_MODE" python3 -c '
import json, sys, re, os
TEST_PATTERN = re.compile(r"(\.(test|spec)\.(ts|tsx|js|jsx)$|(^|/)tests/|(^|/)__tests__/|(^|/)test/|(^|/)vendor/)")
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
    print("[TS-01] WARN: ast-grep JSON parsing failed: " + str(e), file=sys.stderr)
    sys.exit(1)
for m in matches:
    f = m.get("file", "")
    if TEST_PATTERN.search(f):
        continue
    line = m.get("range", {}).get("start", {}).get("line", 0) + 1
    # Baseline filtering: only report problems on new lines in diff.
    # Use in_diff_mode instead of added_set non-empty to determine the diff mode.
    # Avoid falling back to full scan when added_set is empty when only deleting rows.
    if in_diff_mode and (f + ":" + str(line)) not in added_set:
        continue
    msg = m.get("message", "'any' type usage")
    print("[TS-01] " + f + ":" + str(line) + " [review] [this-line] OBSERVATION: " + msg)
' < "${_ASG_TMPOUT}" >> "$RESULTS" || {
          echo "[TS-01] WARN: python3 processing failed, use grep fallback" >&2
          _USE_GREP_FALLBACK=true
        }
      else
        echo "[TS-01] WARN: ast-grep scan failed (the rule file may be missing), use grep fallback" >&2
        _USE_GREP_FALLBACK=true
      fi
    fi
  fi
else
  _USE_GREP_FALLBACK=true
fi

if [[ "$_USE_GREP_FALLBACK" == true ]]; then
  list_ts_files "${TARGET_DIR}" \
    | filter_non_test \
    | while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        grep -nE '(:\s*any\b|\bas\s+any\b)' "$f" 2>/dev/null \
          | grep -v '^\s*//' \
          | while IFS= read -r line_info; do
              LINE_NUM=$(echo "$line_info" | cut -d: -f1)
              # Baseline filtering: only report problems on new lines
              if [[ "$_IN_DIFF_MODE" == true ]]; then
                grep -qxF "${f}:${LINE_NUM}" "$_LINEMAP" 2>/dev/null || continue
              fi
              echo "[TS-01] ${f}:${LINE_NUM} [review] [this-line] OBSERVATION: 'any' type usage"
            done
      done >> "$RESULTS" || true
fi

# --- TS-02: @ts-ignore and @ts-nocheck (comment instructions, grep accuracy is sufficient) ---
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$file" ]] && continue

  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    # Baseline filtering: only report problems on new lines
    if [[ "$_IN_DIFF_MODE" == true ]]; then
      grep -qxF "${file}:${LINE_NUM}" "$_LINEMAP" 2>/dev/null || continue
    fi
    echo "[TS-02] ${file}:${LINE_NUM} [review] [this-line] OBSERVATION: uses '@ts-ignore' to suppress type check" >> "$RESULTS"
  done < <(grep -n '@ts-ignore' "$file" 2>/dev/null || true)

  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    # Baseline filtering: only report problems on new lines
    if [[ "$_IN_DIFF_MODE" == true ]]; then
      grep -qxF "${file}:${LINE_NUM}" "$_LINEMAP" 2>/dev/null || continue
    fi
    echo "[TS-02] ${file}:${LINE_NUM} [review] [this-line] OBSERVATION: uses '@ts-nocheck' to disable type checking for entire file" >> "$RESULTS"
  done < <(grep -n '@ts-nocheck' "$file" 2>/dev/null || true)

done < <(list_ts_files "$TARGET_DIR" | filter_non_test)

apply_suppression_filter "$RESULTS"
COUNT_01=$(grep -cE '^\[TS-01\]' "$RESULTS" || true)
COUNT_02=$(grep -cE '^\[TS-02\]' "$RESULTS" || true)
COUNT=$((COUNT_01 + COUNT_02))

if [[ "$COUNT" -eq 0 ]]; then
  echo "[TS-01] PASS: no type abuse detected"
  exit 0
fi

if [[ "$COUNT_01" -gt 0 ]]; then
  echo "[TS-01] ${COUNT_01} 'any' type usage instance(s):"
  grep -E '^\[TS-01\]' "$RESULTS"
fi

if [[ "$COUNT_02" -gt 0 ]]; then
  echo "[TS-02] ${COUNT_02} @ts-ignore/@ts-nocheck instance(s):"
  grep -E '^\[TS-02\]' "$RESULTS"
fi

echo ""
echo "SCOPE: this-line only — do not modify tsconfig.json, disable type checking globally, or broaden suppressions"
echo "ACTION: REVIEW"

if [[ "$STRICT" == "true" ]]; then
  exit 1
fi
