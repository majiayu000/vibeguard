#!/usr/bin/env bash
# VibeGuard Go Guard: 检测未检查的 error 返回值 (GO-01)
#
# 使用 ast-grep AST 级别扫描，精确识别 `_ = func()` 赋值语句。
# ast-grep 自动区分代码结构，不会误报 for range 子句中的 _ 变量。
#
# 用法:
#   bash check_error_handling.sh [target_dir]
#   bash check_error_handling.sh --strict [target_dir]
#
# 排除:
#   - *_test.go 测试文件
#   - vendor/ 目录

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"

# --- Baseline/diff 过滤：只报告新增行上的问题（pre-commit 或 --baseline 模式）---
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
    echo "[GO-01] WARN: python3 不可用，使用 grep fallback" >&2
    _USE_GREP_FALLBACK=true
  else
    # staged 模式：只扫 staged Go 文件，避免全仓扫描阻塞无关提交
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
    print("[GO-01] WARN: ast-grep JSON 解析失败: " + str(e), file=sys.stderr)
    sys.exit(1)
for m in matches:
    f = m.get("file", "")
    if TEST_PATH.search(f):
        continue
    line = m.get("range", {}).get("start", {}).get("line", 0) + 1
    # Baseline 过滤：只报告 diff 新增行上的问题。
    # 用 in_diff_mode 而非 added_set 非空来判断 diff 模式，
    # 避免仅删除行时 added_set 为空导致回退到全量扫描。
    if in_diff_mode and (f + ":" + str(line)) not in added_set:
        continue
    msg = m.get("message", "error 返回值被丢弃")
    print("[GO-01] " + f + ":" + str(line) + " " + msg)
' < "${_ASG_TMPOUT}" > "${TMPFILE}" || {
          echo "[GO-01] WARN: python3 处理失败，使用 grep fallback" >&2
          _USE_GREP_FALLBACK=true
        }
      else
        echo "[GO-01] WARN: ast-grep 扫描失败（规则文件可能缺失），使用 grep fallback" >&2
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
                # Baseline 过滤：只报告新增行上的问题
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
  echo "FIX: Replace _ = fn() with err := fn(); if err != nil { return fmt.Errorf(\"context: %w\", err) }"
  echo "DO NOT: Modify function signatures or upstream callers"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
