#!/usr/bin/env bash
# VibeGuard Rust Guard: 检测生产代码中的 unwrap()/expect() (RS-03)
#
# 两种模式:
#   Pre-commit 模式 (VIBEGUARD_STAGED_FILES 已设置):
#     只扫描 git diff --cached 新增行 (以 + 开头) 中的 unwrap/expect。
#     已有代码不阻塞提交，只检查本次新增的风险。
#
#   Standalone 模式 (手动运行):
#     扫描全量代码中非测试区域的 unwrap/expect。
#
# 用法:
#   bash check_unwrap_in_prod.sh [target_dir]
#   bash check_unwrap_in_prod.sh --strict [target_dir]
#
# 排除 (两种模式通用):
#   - tests/ 目录、benches/ 目录、examples/ 目录
#   - 文件名为 tests.rs、test_helpers.rs、或包含 test_ / _test 的文件
#   - #[cfg(test)] 行之后的所有代码
#   - unwrap_or / unwrap_or_else / unwrap_or_default（安全的变体）
#   - 注释行

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

# 路径排除 pattern（test 文件）
TEST_PATH_PATTERN='(/tests/|/test_|_test\.rs$|tests\.rs$|test_helpers\.rs$|/examples/|/benches/)'

# unwrap 安全变体 pattern
SAFE_VARIANT_PATTERN='unwrap_or|unwrap_or_else|unwrap_or_default'

# --- Pre-commit 模式：只扫 staged diff 新增行 ---
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
  # 获取 staged rs 文件，排除 test 路径
  STAGED_RS=$(grep '\.rs$' "${VIBEGUARD_STAGED_FILES}" | { grep -vE "${TEST_PATH_PATTERN}" || true; })

  if [[ -n "${STAGED_RS}" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" || ! -f "$f" ]] && continue
      # git diff --cached -U0: 只看新增行，不带上下文
      git diff --cached -U0 -- "${f}" 2>/dev/null \
        | grep '^+' \
        | grep -v '^+++' \
        | grep -E '\.(unwrap|expect)\(' \
        | grep -v "${SAFE_VARIANT_PATTERN}" \
        | grep -v '^\+[[:space:]]*//' \
        | while IFS= read -r line; do
            echo "[RS-03] ${f}: ${line}"
          done
    done <<< "${STAGED_RS}"
  fi > "${TMPFILE}" || true

# --- Standalone 模式：全量扫描（排除 test scope）---
else
  # filter_test_scope: #[cfg(test)] 行之后的代码视为 test
  filter_test_scope() {
    local file="$1"
    local cfg_test_line
    cfg_test_line=$(grep -n '#\[cfg(test)\]' "${file}" 2>/dev/null | head -1 | cut -d: -f1)

    while IFS= read -r hit; do
      if [[ -z "${cfg_test_line}" ]]; then
        echo "${hit}"
      else
        local hit_line
        hit_line=$(echo "${hit}" | cut -d: -f1)
        if [[ "${hit_line}" -lt "${cfg_test_line}" ]]; then
          echo "${hit}"
        fi
      fi
    done
  }

  list_rs_files "${TARGET_DIR}" \
    | { grep -vE "${TEST_PATH_PATTERN}" || true; } \
    | while IFS= read -r f; do
        if [[ -f "${f}" ]]; then
          grep -nE '\.(unwrap|expect)\(' "${f}" 2>/dev/null \
            | grep -vE "${SAFE_VARIANT_PATTERN}" \
            | filter_test_scope "${f}" \
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
