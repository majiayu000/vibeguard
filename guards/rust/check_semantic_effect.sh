#!/usr/bin/env bash
# VibeGuard Rust Guard: 检测动作语义与副作用不一致 (RS-13)
#
# 目标问题：
# - 函数/工具名称包含 done/update/delete/remove/add/create/set 等动作语义
# - 但函数体没有可见状态写入或事件发射，可能是“语义承诺未兑现”
#
# 用法:
#   bash check_semantic_effect.sh [target_dir]
#   bash check_semantic_effect.sh --strict [target_dir]
#
# 允许列表:
#   在目标仓库根目录创建 .vibeguard-semantic-effect-allowlist
#   每行一个函数名（如 mark_done）

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"

ALLOWLIST_FILE="${TARGET_DIR}/.vibeguard-semantic-effect-allowlist"
ALLOWLIST_AWK=""
if [[ -f "${ALLOWLIST_FILE}" ]]; then
  while IFS= read -r name; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    ALLOWLIST_AWK="${ALLOWLIST_AWK}${name}\n"
  done < "${ALLOWLIST_FILE}"
fi

TMP_RS=$(create_tmpfile)
list_rs_files "${TARGET_DIR}" \
  | { grep -vE '(/tests/|/test_|_test\.rs$)' || true; } \
  > "${TMP_RS}"

if [[ ! -s "${TMP_RS}" ]]; then
  echo "No Rust source files found."
  exit 0
fi

REPORT=$(while IFS= read -r f; do
  [[ -f "${f}" ]] || continue
  lower_path="${f,,}"
  # 聚焦行为命令相关模块，减少纯函数误报
  if [[ "${lower_path}" != *task* && "${lower_path}" != *todo* && "${lower_path}" != *tool* && "${lower_path}" != *command* ]]; then
    continue
  fi

  awk -v file="${f}" -v allowlist="${ALLOWLIST_AWK}" '
    BEGIN {
      IGNORECASE = 1
      n = split(allowlist, arr, "\n")
      for (i = 1; i <= n; i++) {
        if (arr[i] != "") skip[arr[i]] = 1
      }
      in_fn = 0
      brace_depth = 0
    }

    function is_action_name(name) {
      lname = tolower(name)
      if (lname ~ /(^|_)(mark_)?done$/) return 1
      if (lname ~ /^(update|delete|remove|add|create|set)_[a-z0-9_]+$/) return 1
      if (lname ~ /^(task|todo).*(done|update|delete|remove|add|create)$/) return 1
      return 0
    }

    {
      line = $0

      if (!in_fn) {
        if (line ~ /fn[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/) {
          fn_name = line
          sub(/^.*fn[[:space:]]+/, "", fn_name)
          sub(/[^A-Za-z0-9_].*$/, "", fn_name)
          if (is_action_name(fn_name) && !(fn_name in skip)) {
            in_fn = 1
            start_line = NR
            has_effect = 0
            has_result = 0
            brace_depth = 0
          }
        }
      }

      if (in_fn) {
        lower = tolower(line)
        # 可见状态写入/事件发射信号
        if (lower ~ /\.(insert|push|remove|retain|update|replace|set)[[:space:]]*\(/ ||
            lower ~ /::(insert|push|remove|update|set|replace|write)[[:space:]]*\(/ ||
            lower ~ /\b(write|save|commit|emit|publish|dispatch|send|persist)\b/) {
          has_effect = 1
        }
        # 结果构造信号：通常是工具输出文本/Result
        if (lower ~ /(ok\(|err\(|format!\(|json!\(|to_string\()/) {
          has_result = 1
        }

        tmp = line
        open_count = gsub(/\{/, "{", tmp)
        tmp = line
        close_count = gsub(/\}/, "}", tmp)
        brace_depth += open_count - close_count

        if (brace_depth <= 0 && line ~ /\}/) {
          if (!has_effect && has_result) {
            printf "%s:%d:%s\n", file, start_line, fn_name
          }
          in_fn = 0
        }
      }
    }
  ' "${f}" 2>/dev/null || true
done < "${TMP_RS}")

if [[ -z "${REPORT}" ]]; then
  echo "No semantic-effect mismatches detected."
  exit 0
fi

COUNT=$(echo "${REPORT}" | sed '/^$/d' | wc -l | tr -d ' ')
echo "[RS-13] Found ${COUNT} action-like function(s) without visible side-effects:"
while IFS= read -r line; do
  [[ -n "${line}" ]] && echo "  - ${line}"
done <<< "${REPORT}"
echo "  修复："
echo "    1. 动作函数应显式写状态或发事件（insert/update/remove/emit 等）"
echo "    2. 若函数本意只是查询/格式化，重命名为 query/format/describe 语义"
echo "    3. 纯函数可加入 .vibeguard-semantic-effect-allowlist"

if [[ "${STRICT}" == true ]]; then
  exit 1
fi
