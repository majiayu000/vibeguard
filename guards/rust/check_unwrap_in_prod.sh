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
      git diff --cached -U0 -- "${f}" 2>/dev/null \
        | grep '^+' \
        | grep -v '^+++' \
        | grep -E '\.(unwrap|expect)\(' \
        | grep -v 'unwrap_or\|unwrap_or_else\|unwrap_or_default' \
        | grep -v '^\+[[:space:]]*//' \
        | while IFS= read -r line; do
            echo "[RS-03] ${f}: ${line}"
          done
    done <<< "${STAGED_RS}"
  fi > "${TMPFILE}" || true

# --- Standalone 模式：ast-grep AST 扫描（精确识别调用表达式，跳过注释）---
elif command -v ast-grep >/dev/null 2>&1; then
  list_rs_files "${TARGET_DIR}" \
    | { grep -vE "${TEST_PATH_PATTERN}" || true; } \
    | while IFS= read -r f; do
        [[ -f "${f}" ]] || continue
        # 获取 #[cfg(test)] 分界线（该行及之后视为测试代码）
        CFG_LINE=$(grep -n '#\[cfg(test)\]' "${f}" 2>/dev/null | head -1 | cut -d: -f1 || true)
        CFG_LINE="${CFG_LINE:-0}"

        ast-grep scan \
          --rule "${RULES_DIR}/rs-03-unwrap.yml" \
          --json "${f}" 2>/dev/null \
        | python3 -c "
import json, sys
cfg_line = int(sys.argv[1])
data = sys.stdin.read().strip()
if not data:
    sys.exit(0)
try:
    matches = json.loads(data)
except Exception:
    sys.exit(0)
for m in matches:
    l = m.get('range', {}).get('start', {}).get('line', 0) + 1
    if cfg_line > 0 and l >= cfg_line:
        continue
    fname = m.get('file', '')
    msg = m.get('message', '')
    print('[RS-03] ' + fname + ':' + str(l) + ' ' + msg)
" "${CFG_LINE}" 2>/dev/null || true
      done > "${TMPFILE}" || true

# --- Fallback: ast-grep 不可用时使用 grep ---
else
  list_rs_files "${TARGET_DIR}" \
    | { grep -vE "${TEST_PATH_PATTERN}" || true; } \
    | while IFS= read -r f; do
        if [[ -f "${f}" ]]; then
          CFG_LINE=$(grep -n '#\[cfg(test)\]' "${f}" 2>/dev/null | head -1 | cut -d: -f1 || true)
          grep -nE '\.(unwrap|expect)\(' "${f}" 2>/dev/null \
            | grep -vE 'unwrap_or|unwrap_or_else|unwrap_or_default' \
            | while IFS= read -r hit; do
                HIT_LINE=$(echo "${hit}" | cut -d: -f1)
                if [[ -z "${CFG_LINE}" ]] || [[ "${HIT_LINE}" -lt "${CFG_LINE}" ]]; then
                  echo "${hit}"
                fi
              done \
            | sed "s|^|${f}:|" || true
        fi
      done \
    | awk '!/^[[:space:]]*\/\// { print "[RS-03] " $0 }' \
    > "${TMPFILE}" || true
fi

cat "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

echo ""
if [[ ${FOUND} -eq 0 ]]; then
  echo "No unwrap()/expect() in production code."
else
  echo "Found ${FOUND} unwrap()/expect() call(s) in production code."
  echo ""
  echo "修复方法："
  echo "  1. .unwrap() → .map_err(|e| YourError::from(e))? （向上传播错误）"
  echo "  2. .unwrap() → .unwrap_or_default() （提供默认值）"
  echo "  3. .unwrap() → .unwrap_or_else(|| fallback()) （延迟计算默认值）"
  echo "  4. .expect(\"msg\") → match / if let （自定义处理逻辑）"
  echo "  5. main() 中 → 使用 anyhow::Result<()> 配合 ? 操作符"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
