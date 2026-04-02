#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-03] console residual detection
#
# Use ast-grep to do AST level detection, only match the actual calling expression, skip comments and strings.
# When ast-grep is unavailable, fall back to grep detection.
# Complementing the real-time detection of post-edit-guard, this script performs full project-level scanning.
#
# Usage:
#   bash check_console_residual.sh [--strict] [target_dir]
#
# --strict mode: any violation exits with a non-zero exit code

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"
source "${SCRIPT_DIR}/common.sh"
parse_guard_args "$@"

# CLI projects allow using the console, skipping the entire check
_IS_CLI=false
if [[ -f "${TARGET_DIR}/package.json" ]]; then
  grep -qE '"bin"' "${TARGET_DIR}/package.json" 2>/dev/null && _IS_CLI=true
  grep -qE '"[^"]*":\s*"[^"]*cli[^"]*"' "${TARGET_DIR}/package.json" 2>/dev/null && _IS_CLI=true
fi
ls "${TARGET_DIR}/src/cli."* "${TARGET_DIR}/cli."* 2>/dev/null | grep -q . && _IS_CLI=true || true
if [[ "$_IS_CLI" == true ]]; then
  echo "[TS-03] SKIP: CLI project, console is the normal output mode"
  exit 0
fi

RESULTS=$(create_tmpfile)

# --- Baseline/diff filtering: only report problems on new lines (pre-commit or --baseline mode) ---
_LINEMAP=""
_IN_DIFF_MODE=false
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] || [[ -n "${BASELINE_COMMIT:-}" ]]; then
  _IN_DIFF_MODE=true
  _LINEMAP=$(create_tmpfile)
  vg_build_diff_linemap "$_LINEMAP" '\.(ts|tsx|js|jsx)$'
fi

_USE_GREP_FALLBACK=false

if command -v ast-grep >/dev/null 2>&1; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[TS-03] WARN: python3 is not available, use grep fallback" >&2
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
          --rule "${RULES_DIR}/ts-03-console.yml" \
          --json \
          "${_ASG_TARGETS[@]}" > "${_ASG_TMPOUT}" 2>/dev/null; then
        VIBEGUARD_TARGET_DIR="${TARGET_DIR}" VG_DIFF_LINEMAP="$_LINEMAP" VG_IN_DIFF_MODE="$_IN_DIFF_MODE" python3 -c '
import json, sys, re, os

TARGET_DIR_PY = os.environ.get("VIBEGUARD_TARGET_DIR", "")
linemap_path = os.environ.get("VG_DIFF_LINEMAP", "")
in_diff_mode = os.environ.get("VG_IN_DIFF_MODE", "false") == "true"
added_set = set()
if linemap_path and os.path.isfile(linemap_path):
    with open(linemap_path) as lm:
        for entry in lm:
            added_set.add(entry.strip())

TEST_PATTERN = re.compile(r"(\.(test|spec)\.(ts|tsx|js|jsx)$|(^|/)tests/|(^|/)__tests__/|(^|/)test/|(^|/)vendor/)")
LOGGER_PATTERN = re.compile(r"(logger|logging|log\.config|/debug\.|/debug/)")
MCP_MARKERS = {"StdioServerTransport", "new Server(", "McpServer"}

mcp_cache = {}

def is_mcp(filepath):
    if filepath not in mcp_cache:
        try:
            with open(filepath, "r", errors="ignore") as fh:
                content = fh.read()
            mcp_cache[filepath] = any(m in content for m in MCP_MARKERS)
        except Exception:
            mcp_cache[filepath] = False
    return mcp_cache[filepath]

data = sys.stdin.read().strip()
if not data:
    sys.exit(0)
try:
    matches = json.loads(data)
except Exception as e:
    print("[TS-03] WARN: ast-grep JSON parsing failed: " + str(e), file=sys.stderr)
    sys.exit(1)

for m in matches:
    f = m.get("file", "")
    if TEST_PATTERN.search(f):
        continue
    rel_f = os.path.relpath(f, TARGET_DIR_PY) if TARGET_DIR_PY else f
    if LOGGER_PATTERN.search(rel_f):
        continue
    if is_mcp(f):
        continue
    line = m.get("range", {}).get("start", {}).get("line", 0) + 1
    # Baseline filtering: only report problems on new lines in diff.
    # Use in_diff_mode instead of added_set non-empty to determine the diff mode.
    # Avoid falling back to full scan when added_set is empty when only deleting rows.
    if in_diff_mode and (f + ":" + str(line)) not in added_set:
        continue
    msg = m.get("message", "console residual")
    print("[TS-03] " + f + ":" + str(line) + " [review] [this-line] OBSERVATION: " + msg)
' < "${_ASG_TMPOUT}" >> "$RESULTS" || {
          echo "[TS-03] WARN: python3 processing failed, use grep fallback" >&2
          _USE_GREP_FALLBACK=true
        }
      else
        echo "[TS-03] WARN: ast-grep scan failed (the rule file may be missing), use grep fallback" >&2
        _USE_GREP_FALLBACK=true
      fi
    fi
  fi
else
  _USE_GREP_FALLBACK=true
fi

if [[ "$_USE_GREP_FALLBACK" == true ]]; then
  # Fallback: grep (ast-grep is not available)
  # Note: grep fallback cannot distinguish console in comments/strings, there may be a small number of false positives
  MCP_MARKERS_PATTERN='StdioServerTransport|new Server\(|McpServer'
  list_ts_files "${TARGET_DIR}" \
    | filter_non_test \
    | while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        # Use relative paths to filter logger/debug tool files to avoid parent directory name pollution
        _rel_f="${f#${TARGET_DIR}/}"
        echo "${_rel_f}" | grep -qE '(logger|logging|log\.config|/debug\.|/debug/)' && continue
        # Skip MCP files
        grep -qE "${MCP_MARKERS_PATTERN}" "$f" 2>/dev/null && continue
        grep -nE '\bconsole\.(log|warn|error|info|debug|trace)\b' "$f" 2>/dev/null \
          | grep -v '^\s*//' \
          | while IFS= read -r line_info; do
              LINE_NUM=$(echo "$line_info" | cut -d: -f1)
              # Baseline filtering: only report problems on new lines
              if [[ "$_IN_DIFF_MODE" == true ]]; then
                grep -qxF "${f}:${LINE_NUM}" "$_LINEMAP" 2>/dev/null || continue
              fi
              echo "[TS-03] ${f}:${LINE_NUM} [review] [this-line] OBSERVATION: console residual"
            done
      done >> "$RESULTS" || true
fi

apply_suppression_filter "$RESULTS"
COUNT=$(wc -l < "$RESULTS" | tr -d ' ')

if [[ "$COUNT" -eq 0 ]]; then
  echo "[TS-03] PASS: No console residue detected"
  exit 0
fi

echo "[TS-03] ${COUNT} console residual instance(s):"
echo
cat "$RESULTS"
echo ""
echo "SCOPE: this-line only — do not create logger modules, modify other files, or fix console usage outside this line"
echo "ACTION: REVIEW — skip if this is a CLI project (check bin field in package.json)"

if [[ "$STRICT" == "true" ]]; then
  exit 1
fi
