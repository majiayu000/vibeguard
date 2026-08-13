#!/usr/bin/env bash
# VibeGuard Rust Guard: Detect unwrap()/expect() in production code (RS-03)
#
# Two modes:
# Pre-commit mode (VIBEGUARD_STAGED_FILES is set):
# grep diff adds new lines (starting with +) and retains the original logic (diff is not a file and cannot be processed by ast-grep).
#
# Standalone mode (manual operation):
# Use ast-grep AST level scanning to eliminate false positives in comments and precisely exclude unwrap_or* variants.
#
# Usage:
#   bash check_unwrap_in_prod.sh [target_dir]
#   bash check_unwrap_in_prod.sh --strict [target_dir]
#
# Exclude (common to both modes):
# - tests/ directory, benches/ directory, examples/ directory
# - A file named tests.rs, test_helpers.rs, or a file containing test_ / _test
# - All code after the #[cfg(test)] line

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"

# Stateful shell fallback used when ast-grep or its JSON parser is unavailable.
# Keep its lexical states aligned with the Python scanners below: braces inside
# strings/comments do not affect #[cfg(test)] scope, while lifetimes and labels
# remain ordinary Rust syntax rather than being mistaken for character literals.
scan_with_awk_fallback() {
  local file="$1"
  awk '
    function char_literal_end(line, start,    end, close_pos, tail) {
      end = start + 1
      if (end > length(line)) return 0
      if (substr(line, end, 1) == "\\") {
        end++
        if (substr(line, end, 1) == "u" && substr(line, end + 1, 1) == "{") {
          tail = substr(line, end + 2)
          close_pos = index(tail, "}")
          if (!close_pos) return 0
          end = end + 2 + close_pos
        } else if (substr(line, end, 1) == "x") {
          end += 3
        } else {
          end++
        }
      } else {
        end++
      }
      return substr(line, end, 1) == "\047" ? end : 0
    }

    function scan_line(line,    n, i, c, pair, rest, pos, prefix_len, marker, hashes, j, char_end) {
      code_line = ""
      brace_delta = 0
      n = length(line)
      i = 1
      while (i <= n) {
        if (raw_string_end != "") {
          rest = substr(line, i)
          pos = index(rest, raw_string_end)
          if (!pos) return brace_delta
          i += pos - 1 + length(raw_string_end)
          raw_string_end = ""
          continue
        }
        c = substr(line, i, 1)
        pair = substr(line, i, 2)
        if (in_string) {
          if (c == "\\") i += 2
          else if (c == "\"") { in_string = 0; i++ }
          else i++
          continue
        }
        if (block_comment_depth) {
          if (pair == "/*") { block_comment_depth++; i += 2 }
          else if (pair == "*/") { block_comment_depth--; i += 2 }
          else i++
          continue
        }
        if (pair == "//") break
        if (pair == "/*") { block_comment_depth = 1; i += 2; continue }

        prefix_len = 0
        if (pair == "br" || pair == "cr") prefix_len = 2
        else if (c == "r") prefix_len = 1
        if (prefix_len && (i == 1 || substr(line, i - 1, 1) !~ /[[:alnum:]_]/)) {
          marker = i + prefix_len
          while (marker <= n && substr(line, marker, 1) == "#") marker++
          if (marker <= n && substr(line, marker, 1) == "\"") {
            hashes = marker - i - prefix_len
            raw_string_end = "\""
            for (j = 0; j < hashes; j++) raw_string_end = raw_string_end "#"
            i = marker + 1
            continue
          }
        }

        if (c == "\"") { in_string = 1; i++; continue }
        if (c == "\047") {
          char_end = char_literal_end(line, i)
          if (char_end) { i = char_end + 1; continue }
        }
        code_line = code_line c
        if (c == "{") brace_delta++
        else if (c == "}") brace_delta--
        i++
      }
      return brace_delta
    }

    {
      delta = scan_line($0)
      if (code_line ~ /^[[:space:]]*#\[cfg\(test\)\]/) {
        if (code_line ~ /(mod|fn|impl|struct|enum|type|trait)[[:space:]]/) {
          in_test_mod = 1
          brace_depth = delta
          if (brace_depth <= 0) in_test_mod = 0
        } else {
          pending_test_attr = 1
        }
        next
      }
      if (pending_test_attr && code_line ~ /^[[:space:]]*#\[/) next
      if (pending_test_attr && code_line ~ /(mod|fn|impl|struct|enum|type|trait)[[:space:]]/) {
        in_test_mod = 1
        pending_test_attr = 0
        brace_depth = delta
        if (brace_depth <= 0) in_test_mod = 0
        next
      }
      if (pending_test_attr) pending_test_attr = 0
      if (in_test_mod) {
        brace_depth += delta
        if (brace_depth <= 0) in_test_mod = 0
        next
      }
      if (code_line ~ /\.(unwrap|expect)\(/) {
        print "[RS-03] " FILENAME ":" NR ": " $0
      }
    }
  ' "${file}"
}

# --- Pre-commit mode: grep diff new lines (ast-grep does not process diff text) ---
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
  if ! grep -q '\.rs$' "${VIBEGUARD_STAGED_FILES}" 2>/dev/null; then
    STAGED_RS=""
  else
    STAGED_RS=$(grep '\.rs$' "${VIBEGUARD_STAGED_FILES}" | filter_rs_prod_paths)
  fi

  if [[ -n "${STAGED_RS}" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" || ! -f "$f" ]] && continue
      if command -v python3 >/dev/null 2>&1; then
        # Parse hunk headers to include real line numbers so apply_suppression_filter
        # can honour vibeguard-disable-next-line comments in the committed file.
        # Save diff to a temp file so we can re-read it on Python failure.
        _diff_tmp=$(create_tmpfile)
        vg_staged_file_diff "${f}" > "${_diff_tmp}"
        # Write Python script to temp file to avoid bash escaping issues with regex
        _diff_py=$(create_tmpfile)
        cat > "${_diff_py}" << 'DIFFPYEOF'
import sys, re

fname = sys.argv[1]
danger_pat  = re.compile(r'\.(unwrap\(|expect\()')
comment_pat = re.compile(r'^\s*//')
hunk_pat    = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')
_ITEM_KW    = re.compile(r'\b(mod|fn|impl|struct|enum|type|trait)\b')

# --- Build test_lines set from original file (reuse standalone logic) ---
_raw_string_end = None
_in_string = False
_block_comment_depth = 0

def _count_braces(s):
    global _raw_string_end, _in_string, _block_comment_depth
    depth = 0
    i = 0
    while i < len(s):
        if _raw_string_end is not None:
            end = s.find(_raw_string_end, i)
            if end < 0:
                return depth
            i = end + len(_raw_string_end)
            _raw_string_end = None
            continue
        if _in_string:
            if s[i] == '\\':
                i += 2
            elif s[i] == '"':
                _in_string = False
                i += 1
            else:
                i += 1
            continue
        if _block_comment_depth:
            if s.startswith('/*', i):
                _block_comment_depth += 1
                i += 2
            elif s.startswith('*/', i):
                _block_comment_depth -= 1
                i += 2
            else:
                i += 1
            continue
        if s.startswith('//', i):
            break
        if s.startswith('/*', i):
            _block_comment_depth = 1
            i += 2
            continue

        prefix_len = 0
        if s.startswith(('br', 'cr'), i):
            prefix_len = 2
        elif s.startswith('r', i):
            prefix_len = 1
        if prefix_len and (i == 0 or not (s[i - 1].isalnum() or s[i - 1] == '_')):
            marker = i + prefix_len
            while marker < len(s) and s[marker] == '#':
                marker += 1
            if marker < len(s) and s[marker] == '"':
                _raw_string_end = '"' + ('#' * (marker - i - prefix_len))
                i = marker + 1
                continue

        if s[i] == '"':
            _in_string = True
            i += 1
            continue
        if s[i] == "'":
            end = i + 1
            if end < len(s) and s[end] == '\\':
                end += 1
                if end < len(s) and s[end] == 'u' and s.startswith('{', end + 1):
                    close = s.find('}', end + 2)
                    end = close + 1 if close >= 0 else len(s)
                elif end < len(s) and s[end] == 'x':
                    end += 3
                else:
                    end += 1
            else:
                end += 1
            if end < len(s) and s[end] == "'":
                i = end + 1
            else:
                # A lifetime or loop label is not a character literal.
                i += 1
            continue
        if s[i] == '{':
            depth += 1
        elif s[i] == '}':
            depth -= 1
        i += 1
    return depth

test_lines = set()
try:
    with open(fname) as _src:
        _all = _src.readlines()
    _pending = False; _in_mod = False; _depth = 0
    for _i, _ln in enumerate(_all, 1):
        _s = _ln.strip()
        if _s.startswith('#[cfg(test)]'):
            test_lines.add(_i)
            if _ITEM_KW.search(_s[len('#[cfg(test)]'):]):
                _in_mod = True; _depth = _count_braces(_s)
                if _depth <= 0: _in_mod = False
            else:
                _pending = True
            continue
        if _pending:
            if _s.startswith('#['):
                test_lines.add(_i); continue
            _pending = False
            if _ITEM_KW.search(_s):
                _in_mod = True; _depth = _count_braces(_s); test_lines.add(_i)
                if _depth <= 0: _in_mod = False
            continue
        if _in_mod:
            test_lines.add(_i); _depth += _count_braces(_s)
            if _depth <= 0: _in_mod = False
except Exception:
    pass

# --- Scan diff lines, skip test_lines ---
current_line = 0
for raw in sys.stdin:
    line = raw.rstrip('\n')
    m = hunk_pat.match(line)
    if m:
        current_line = int(m.group(1)) - 1
        continue
    if line.startswith('+++') or line.startswith('---'):
        continue
    if line.startswith('+'):
        current_line += 1
        if current_line in test_lines:
            continue
        content = line[1:]
        if danger_pat.search(content) and not comment_pat.match(content):
            print('[RS-03] ' + fname + ':' + str(current_line) + ' ' + line)
    elif not line.startswith('-'):
        current_line += 1
DIFFPYEOF
        if ! python3 "${_diff_py}" "${f}" < "${_diff_tmp}" 2>/dev/null; then
          echo "[RS-03] WARN: python3 failed to parse ${f}, use grep fallback" >&2
          <"${_diff_tmp}" grep '^+' \
            | grep -v '^+++' \
            | grep -E '\.(unwrap|expect)\(' \
            | grep -v '^\+[[:space:]]*//' \
            | while IFS= read -r line; do
                echo "[RS-03] ${f}: ${line}"
              done || true
        fi
      else
        # Fallback when python3 is unavailable: no line numbers; suppression won't apply.
        vg_staged_file_diff "${f}" \
          | grep '^+' \
          | grep -v '^+++' \
          | grep -E '\.(unwrap|expect)\(' \
          | grep -v '^\+[[:space:]]*//' \
          | while IFS= read -r line; do
              echo "[RS-03] ${f}: ${line}"
            done || true
      fi
    done <<< "${STAGED_RS}"
  fi > "${TMPFILE}" || true

# --- Standalone mode: ast-grep AST scan (accurately identify calling expressions, skip comments) ---
elif command -v ast-grep >/dev/null 2>&1; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[RS-03] WARN: python3 is not available, use grep fallback" >&2
    list_rs_prod_files "${TARGET_DIR}" \
      | while IFS= read -r f; do
          [[ -f "${f}" ]] && scan_with_awk_fallback "${f}"
        done \
      > "${TMPFILE}" || true
  else
    _ASG_PER_FILE=$(create_tmpfile)
    _PY_SCRIPT=$(create_tmpfile)
    cat > "${_PY_SCRIPT}" << 'PYEOF'
import json, sys, re

file_path = sys.argv[1]
test_lines = set()

_raw_string_end = None
_in_string = False
_block_comment_depth = 0

def _count_braces(s):
    global _raw_string_end, _in_string, _block_comment_depth
    depth = 0
    i = 0
    while i < len(s):
        if _raw_string_end is not None:
            end = s.find(_raw_string_end, i)
            if end < 0:
                return depth
            i = end + len(_raw_string_end)
            _raw_string_end = None
            continue
        if _in_string:
            if s[i] == '\\':
                i += 2
            elif s[i] == '"':
                _in_string = False
                i += 1
            else:
                i += 1
            continue
        if _block_comment_depth:
            if s.startswith('/*', i):
                _block_comment_depth += 1
                i += 2
            elif s.startswith('*/', i):
                _block_comment_depth -= 1
                i += 2
            else:
                i += 1
            continue
        if s.startswith('//', i):
            break
        if s.startswith('/*', i):
            _block_comment_depth = 1
            i += 2
            continue

        prefix_len = 0
        if s.startswith(('br', 'cr'), i):
            prefix_len = 2
        elif s.startswith('r', i):
            prefix_len = 1
        if prefix_len and (i == 0 or not (s[i - 1].isalnum() or s[i - 1] == '_')):
            marker = i + prefix_len
            while marker < len(s) and s[marker] == '#':
                marker += 1
            if marker < len(s) and s[marker] == '"':
                _raw_string_end = '"' + ('#' * (marker - i - prefix_len))
                i = marker + 1
                continue

        if s[i] == '"':
            _in_string = True
            i += 1
            continue
        if s[i] == "'":
            end = i + 1
            if end < len(s) and s[end] == '\\':
                end += 1
                if end < len(s) and s[end] == 'u' and s.startswith('{', end + 1):
                    close = s.find('}', end + 2)
                    end = close + 1 if close >= 0 else len(s)
                elif end < len(s) and s[end] == 'x':
                    end += 3
                else:
                    end += 1
            else:
                end += 1
            if end < len(s) and s[end] == "'":
                i = end + 1
            else:
                # A lifetime or loop label is not a character literal.
                i += 1
            continue
        if s[i] == '{':
            depth += 1
        elif s[i] == '}':
            depth -= 1
        i += 1
    return depth

_ITEM_KW = re.compile(r'\b(mod|fn|impl|struct|enum|type|trait)\b')

try:
    with open(file_path) as _src:
        _all = _src.readlines()
    _pending = False
    _in_mod = False
    _depth = 0
    for _i, _ln in enumerate(_all, 1):
        _s = _ln.strip()
        if _s.startswith('#[cfg(test)]'):
            test_lines.add(_i)
            # Inline form: #[cfg(test)] mod tests { ... } on one line
            if _ITEM_KW.search(_s[len('#[cfg(test)]'):]):
                _in_mod = True
                _depth = _count_braces(_s)
                if _depth <= 0:
                    _in_mod = False
            else:
                _pending = True
            continue
        if _pending:
            # Keep pending through additional attribute lines (#[allow(...)], #[tokio::test], etc.)
            if _s.startswith('#['):
                test_lines.add(_i)
                continue
            _pending = False
            if _ITEM_KW.search(_s):
                _in_mod = True
                _depth = _count_braces(_s)
                test_lines.add(_i)
                if _depth <= 0:
                    _in_mod = False
            continue
        if _in_mod:
            test_lines.add(_i)
            _depth += _count_braces(_s)
            if _depth <= 0:
                _in_mod = False
except Exception:
    pass

data = sys.stdin.read().strip()
if not data:
    sys.exit(0)
try:
    matches = json.loads(data)
except Exception as e:
    print('[RS-03] WARN: JSON parsing failed: ' + str(e), file=sys.stderr)
    sys.exit(1)
for m in matches:
    l = m.get('range', {}).get('start', {}).get('line', 0) + 1
    if l in test_lines:
        continue
    fname = m.get('file', '')
    msg = m.get('message', '')
    print('[RS-03] ' + fname + ':' + str(l) + ' ' + msg)
PYEOF
    list_rs_prod_files "${TARGET_DIR}" \
      | while IFS= read -r f; do
          [[ -f "${f}" ]] || continue
          _ASG_FILE_OUT=$(create_tmpfile)
          if ast-grep scan \
              --rule "${RULES_DIR}/rs-03-unwrap.yml" \
              --json "${f}" > "${_ASG_FILE_OUT}" 2>/dev/null; then
            python3 "${_PY_SCRIPT}" "${f}" < "${_ASG_FILE_OUT}" >> "${_ASG_PER_FILE}" || {
            echo "[RS-03] WARN: JSON parsing failed ${f}, use grep fallback" >&2
            scan_with_awk_fallback "${f}" >> "${_ASG_PER_FILE}"
          }
          else
            echo "[RS-03] WARN: ast-grep scan failed ${f}, use grep fallback" >&2
            scan_with_awk_fallback "${f}" >> "${_ASG_PER_FILE}"
          fi
        done
    cat "${_ASG_PER_FILE}" > "${TMPFILE}" || true
  fi

# --- Fallback: Use grep when ast-grep is not available ---
else
  list_rs_prod_files "${TARGET_DIR}" \
    | while IFS= read -r f; do
        [[ -f "${f}" ]] && scan_with_awk_fallback "${f}"
      done \
    > "${TMPFILE}" || true
fi

apply_suppression_filter "${TMPFILE}"
sed 's/^\[RS-03\] /[RS-03] [review] [this-edit] OBSERVATION: /' "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

echo ""
if [[ ${FOUND} -eq 0 ]]; then
  echo "No unwrap()/expect() in production code."
else
  echo "Found ${FOUND} unwrap()/expect() call(s) in production code."
  echo ""
  echo "SCOPE: this-line only — do not fix other unwrap calls, add error types, or change function signatures"
  echo "ACTION: REVIEW"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
