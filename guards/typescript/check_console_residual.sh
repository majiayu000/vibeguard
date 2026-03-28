#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-03] console 残留检测
#
# 使用 ast-grep 做 AST 级别检测，仅匹配实际调用表达式，跳过注释和字符串。
# ast-grep 不可用时，回退到 grep 检测。
# 与 post-edit-guard 的实时检测互补，这个脚本做项目级全量扫描。
#
# 用法：
#   bash check_console_residual.sh [--strict] [target_dir]
#
# --strict 模式：任何违规都以非零退出码退出

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"
source "${SCRIPT_DIR}/common.sh"
parse_guard_args "$@"

# CLI 项目允许使用 console，跳过整个检查
_IS_CLI=false
if [[ -f "${TARGET_DIR}/package.json" ]]; then
  grep -qE '"bin"' "${TARGET_DIR}/package.json" 2>/dev/null && _IS_CLI=true
  grep -qE '"[^"]*":\s*"[^"]*cli[^"]*"' "${TARGET_DIR}/package.json" 2>/dev/null && _IS_CLI=true
fi
ls "${TARGET_DIR}/src/cli."* "${TARGET_DIR}/cli."* 2>/dev/null | grep -q . && _IS_CLI=true || true
if [[ "$_IS_CLI" == true ]]; then
  echo "[TS-03] SKIP: CLI 项目，console 为正常输出方式"
  exit 0
fi

RESULTS=$(create_tmpfile)

# --- Baseline/diff 过滤：只报告新增行上的问题（pre-commit 或 --baseline 模式）---
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
    echo "[TS-03] WARN: python3 不可用，使用 grep fallback" >&2
    _USE_GREP_FALLBACK=true
  else
    # staged 模式：只扫 staged TS 文件，避免全仓扫描阻塞无关提交
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
    print("[TS-03] WARN: ast-grep JSON 解析失败: " + str(e), file=sys.stderr)
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
    # Baseline 过滤：只报告 diff 新增行上的问题。
    # 用 in_diff_mode 而非 added_set 非空来判断 diff 模式，
    # 避免仅删除行时 added_set 为空导致回退到全量扫描。
    if in_diff_mode and (f + ":" + str(line)) not in added_set:
        continue
    msg = m.get("message", "console residual")
    print("[TS-03] [review] [this-line] OBSERVATION: " + f + ":" + str(line) + " " + msg)
' < "${_ASG_TMPOUT}" >> "$RESULTS" || {
          echo "[TS-03] WARN: python3 处理失败，使用 grep fallback" >&2
          _USE_GREP_FALLBACK=true
        }
      else
        echo "[TS-03] WARN: ast-grep 扫描失败（规则文件可能缺失），使用 grep fallback" >&2
        _USE_GREP_FALLBACK=true
      fi
    fi
  fi
else
  _USE_GREP_FALLBACK=true
fi

if [[ "$_USE_GREP_FALLBACK" == true ]]; then
  # Fallback: grep（ast-grep 不可用）
  # 注意：grep fallback 无法区分注释/字符串中的 console，可能有少量误报
  MCP_MARKERS_PATTERN='StdioServerTransport|new Server\(|McpServer'
  list_ts_files "${TARGET_DIR}" \
    | filter_non_test \
    | while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        # 用相对路径过滤 logger/debug 工具文件，避免父目录名污染
        _rel_f="${f#${TARGET_DIR}/}"
        echo "${_rel_f}" | grep -qE '(logger|logging|log\.config|/debug\.|/debug/)' && continue
        # 跳过 MCP 文件
        grep -qE "${MCP_MARKERS_PATTERN}" "$f" 2>/dev/null && continue
        grep -nE '\bconsole\.(log|warn|error|info|debug|trace)\b' "$f" 2>/dev/null \
          | grep -v '^\s*//' \
          | while IFS= read -r line_info; do
              LINE_NUM=$(echo "$line_info" | cut -d: -f1)
              # Baseline 过滤：只报告新增行上的问题
              if [[ "$_IN_DIFF_MODE" == true ]]; then
                grep -qxF "${f}:${LINE_NUM}" "$_LINEMAP" 2>/dev/null || continue
              fi
              echo "[TS-03] [review] [this-line] OBSERVATION: ${f}:${LINE_NUM} console residual"
            done
      done >> "$RESULTS" || true
fi

apply_suppression_filter "$RESULTS"
COUNT=$(wc -l < "$RESULTS" | tr -d ' ')

if [[ "$COUNT" -eq 0 ]]; then
  echo "[TS-03] PASS: 未检测到 console 残留"
  exit 0
fi

echo "[TS-03] ${COUNT} console residual instance(s):"
echo
cat "$RESULTS"
echo ""
echo "FIX: Remove this console.log/warn/error call; keep only if this is a CLI project (check bin field in package.json)"
echo "DO NOT: Create new logger modules, modify other files, or fix console usage outside this line"

if [[ "$STRICT" == "true" ]]; then
  exit 1
fi
