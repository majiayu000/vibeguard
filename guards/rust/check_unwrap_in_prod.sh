#!/usr/bin/env bash
# VibeGuard Rust Guard: 检测生产代码中的 unwrap()/expect() (RS-03)
#
# 两种模式:
#   Pre-commit 模式 (VIBEGUARD_STAGED_FILES 已设置):
#     grep diff 新增行（+开头），保留原有逻辑（diff 不是文件，ast-grep 无法处理）。
#
#   Standalone 模式 (手动运行):
#     使用 ast-grep AST 级别扫描，消除注释中的误报，精确排除 unwrap_or* 变体。
#
# 用法:
#   bash check_unwrap_in_prod.sh [target_dir]
#   bash check_unwrap_in_prod.sh --strict [target_dir]
#
# 排除 (两种模式通用):
#   - tests/ 目录、benches/ 目录、examples/ 目录
#   - 文件名为 tests.rs、test_helpers.rs、或包含 test_ / _test 的文件
#   - #[cfg(test)] 行之后的所有代码

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

# 路径排除 pattern（test 文件）
TEST_PATH_PATTERN='(/tests/|/test_|_test\.rs$|tests\.rs$|test_helpers\.rs$|/examples/|/benches/)'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"

# --- Pre-commit 模式：grep diff 新增行（ast-grep 不处理 diff 文本）---
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
  STAGED_RS=$(grep '\.rs$' "${VIBEGUARD_STAGED_FILES}" | { grep -vE "${TEST_PATH_PATTERN}" || true; })

  if [[ -n "${STAGED_RS}" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" || ! -f "$f" ]] && continue
      if command -v python3 >/dev/null 2>&1; then
        # Parse hunk headers to include real line numbers so apply_suppression_filter
        # can honour vibeguard-disable-next-line comments in the committed file.
        # Save diff to a temp file so we can re-read it on Python failure.
        _diff_tmp=$(create_tmpfile)
        git diff --cached -U0 -- "${f}" 2>/dev/null > "${_diff_tmp}"
        if ! python3 -c "
import sys, re
fname = sys.argv[1]
# \.(unwrap\(|expect\() matches .unwrap( and .expect( but NOT .unwrap_or*(
# because after 'unwrap' the next char must be '(' not '_'.
# Using safe_pat + 'not safe_pat.search()' would exclude lines that have both
# .expect('msg') and .unwrap_or_default() chained, causing false negatives.
danger_pat  = re.compile(r'\.(unwrap\(|expect\()')
comment_pat = re.compile(r'^\s*//')
hunk_pat    = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')
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
        content = line[1:]
        if danger_pat.search(content) and not comment_pat.match(content):
            print('[RS-03] ' + fname + ':' + str(current_line) + ' ' + line)
    elif not line.startswith('-'):
        current_line += 1
" "${f}" < "${_diff_tmp}" 2>/dev/null; then
          echo "[RS-03] WARN: python3 解析失败 ${f}，使用 grep fallback" >&2
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
        git diff --cached -U0 -- "${f}" 2>/dev/null \
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

# --- Standalone 模式：ast-grep AST 扫描（精确识别调用表达式，跳过注释）---
elif command -v ast-grep >/dev/null 2>&1; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[RS-03] WARN: python3 不可用，使用 grep fallback" >&2
    # fall through to grep fallback below
    list_rs_files "${TARGET_DIR}" \
      | { grep -vE "${TEST_PATH_PATTERN}" || true; } \
      | while IFS= read -r f; do
          if [[ -f "${f}" ]]; then
            awk '
              function net_braces(line,    _t, _o, _c) {
                _t = line; gsub(/\/\/.*$/, "", _t); gsub(/"[^"]*"/, "", _t)
                _o = gsub(/{/, "", _t); _c = gsub(/}/, "", _t); return _o - _c
              }
              /^[[:space:]]*#\[cfg\(test\)\]/ {
                if (/(mod|fn|impl|struct|enum|type|trait)[[:space:]]/) {
                  in_test_mod = 1; brace_depth = net_braces($0)
                  if (brace_depth <= 0) in_test_mod = 0
                } else { pending_test_attr = 1 }
                next
              }
              pending_test_attr && /^[[:space:]]*#\[/ { next }
              pending_test_attr && /(mod|fn|impl|struct|enum|type|trait)[[:space:]]/ {
                in_test_mod = 1; pending_test_attr = 0; brace_depth = net_braces($0)
                if (brace_depth <= 0) in_test_mod = 0
                next
              }
              pending_test_attr { pending_test_attr = 0 }
              in_test_mod {
                brace_depth += net_braces($0)
                if (brace_depth <= 0) in_test_mod = 0
                next
              }
              /\.(unwrap|expect)\(/ && !/unwrap_or/ && !/^[[:space:]]*\/\// { print NR ": " $0 }
            ' "${f}" | sed "s|^|${f}:|" || true
          fi
        done \
      | awk '{ print "[RS-03] " $0 }' \
      > "${TMPFILE}" || true
  else
    _ASG_PER_FILE=$(create_tmpfile)
    _PY_SCRIPT=$(create_tmpfile)
    cat > "${_PY_SCRIPT}" << 'PYEOF'
import json, sys, re

file_path = sys.argv[1]
test_lines = set()

def _count_braces(s):
    # Strip string literals and line comments before counting braces
    s = re.sub(r'"(?:[^"\\]|\\.)*"', '', s)   # remove double-quoted string literals
    s = re.sub(r"'(?:[^'\\]|\\.)*'", '', s)   # remove single-quoted char literals
    s = re.sub(r'//.*$', '', s)               # remove line comments
    return s.count('{') - s.count('}')

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
    print('[RS-03] WARN: JSON 解析失败: ' + str(e), file=sys.stderr)
    sys.exit(1)
for m in matches:
    l = m.get('range', {}).get('start', {}).get('line', 0) + 1
    if l in test_lines:
        continue
    fname = m.get('file', '')
    msg = m.get('message', '')
    print('[RS-03] ' + fname + ':' + str(l) + ' ' + msg)
PYEOF
    list_rs_files "${TARGET_DIR}" \
      | { grep -vE "${TEST_PATH_PATTERN}" || true; } \
      | while IFS= read -r f; do
          [[ -f "${f}" ]] || continue
          _ASG_FILE_OUT=$(create_tmpfile)
          if ast-grep scan \
              --rule "${RULES_DIR}/rs-03-unwrap.yml" \
              --json "${f}" > "${_ASG_FILE_OUT}" 2>/dev/null; then
            python3 "${_PY_SCRIPT}" "${f}" < "${_ASG_FILE_OUT}" >> "${_ASG_PER_FILE}" || {
            echo "[RS-03] WARN: JSON 解析失败 ${f}，使用 grep fallback" >&2
            awk '
              function net_braces(line,    _t, _o, _c) {
                _t = line; gsub(/\/\/.*$/, "", _t); gsub(/"[^"]*"/, "", _t)
                _o = gsub(/{/, "", _t); _c = gsub(/}/, "", _t); return _o - _c
              }
              /^[[:space:]]*#\[cfg\(test\)\]/ {
                if (/(mod|fn|impl|struct|enum|type|trait)[[:space:]]/) {
                  in_test_mod = 1; brace_depth = net_braces($0)
                  if (brace_depth <= 0) in_test_mod = 0
                } else { pending_test_attr = 1 }
                next
              }
              pending_test_attr && /^[[:space:]]*#\[/ { next }
              pending_test_attr && /(mod|fn|impl|struct|enum|type|trait)[[:space:]]/ {
                in_test_mod = 1; pending_test_attr = 0; brace_depth = net_braces($0)
                if (brace_depth <= 0) in_test_mod = 0
                next
              }
              pending_test_attr { pending_test_attr = 0 }
              in_test_mod {
                brace_depth += net_braces($0)
                if (brace_depth <= 0) in_test_mod = 0
                next
              }
              /\.(unwrap|expect)\(/ && !/unwrap_or/ && !/^[[:space:]]*\/\// { print "[RS-03] " FILENAME ":" NR ": " $0 }
            ' "${f}" >> "${_ASG_PER_FILE}" || true
          }
          else
            echo "[RS-03] WARN: ast-grep 扫描失败 ${f}，使用 grep fallback" >&2
            awk '
              function net_braces(line,    _t, _o, _c) {
                _t = line; gsub(/\/\/.*$/, "", _t); gsub(/"[^"]*"/, "", _t)
                _o = gsub(/{/, "", _t); _c = gsub(/}/, "", _t); return _o - _c
              }
              /^[[:space:]]*#\[cfg\(test\)\]/ {
                if (/(mod|fn|impl|struct|enum|type|trait)[[:space:]]/) {
                  in_test_mod = 1; brace_depth = net_braces($0)
                  if (brace_depth <= 0) in_test_mod = 0
                } else { pending_test_attr = 1 }
                next
              }
              pending_test_attr && /^[[:space:]]*#\[/ { next }
              pending_test_attr && /(mod|fn|impl|struct|enum|type|trait)[[:space:]]/ {
                in_test_mod = 1; pending_test_attr = 0; brace_depth = net_braces($0)
                if (brace_depth <= 0) in_test_mod = 0
                next
              }
              pending_test_attr { pending_test_attr = 0 }
              in_test_mod {
                brace_depth += net_braces($0)
                if (brace_depth <= 0) in_test_mod = 0
                next
              }
              /\.(unwrap|expect)\(/ && !/unwrap_or/ && !/^[[:space:]]*\/\// { print "[RS-03] " FILENAME ":" NR ": " $0 }
            ' "${f}" >> "${_ASG_PER_FILE}" || true
          fi
        done
    cat "${_ASG_PER_FILE}" > "${TMPFILE}" || true
  fi

# --- Fallback: ast-grep 不可用时使用 grep ---
else
  list_rs_files "${TARGET_DIR}" \
    | { grep -vE "${TEST_PATH_PATTERN}" || true; } \
    | while IFS= read -r f; do
        if [[ -f "${f}" ]]; then
          # Fix RS-03: handle multiple #[cfg(test)] blocks by using awk to track
          # test module scope (brace depth), not just the first occurrence.
          awk '
            function net_braces(line,    _t, _o, _c) {
              _t = line; gsub(/\/\/.*$/, "", _t); gsub(/"[^"]*"/, "", _t)
              _o = gsub(/{/, "", _t); _c = gsub(/}/, "", _t); return _o - _c
            }
            /^[[:space:]]*#\[cfg\(test\)\]/ {
              if (/(mod|fn|impl|struct|enum|type|trait)[[:space:]]/) {
                in_test_mod = 1; brace_depth = net_braces($0)
                if (brace_depth <= 0) in_test_mod = 0
              } else { pending_test_attr = 1 }
              next
            }
            pending_test_attr && /^[[:space:]]*#\[/ { next }
            pending_test_attr && /(mod|fn|impl|struct|enum|type|trait)[[:space:]]/ {
              in_test_mod = 1; pending_test_attr = 0; brace_depth = net_braces($0); next
            }
            pending_test_attr { pending_test_attr = 0 }
            in_test_mod {
              brace_depth += net_braces($0)
              if (brace_depth <= 0) in_test_mod = 0
              next
            }
            /\.(unwrap|expect)\(/ && !/unwrap_or/ && !/^[[:space:]]*\/\// { print NR ": " $0 }
          ' "${f}" | sed "s|^|${f}:|" || true
        fi
      done \
    | awk '{ print "[RS-03] " $0 }' \
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
