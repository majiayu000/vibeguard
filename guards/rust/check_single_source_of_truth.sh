#!/usr/bin/env bash
# VibeGuard Rust Guard: 检测任务系统单一事实源破坏 (RS-12)
#
# 目标问题：
# - Todo* 与 TaskManagement* 两套工具族并存，且同时出现在工具注册链路
# - task/todo 相关全局状态容器过多，可能导致状态源分裂
#
# 用法:
#   bash check_single_source_of_truth.sh [target_dir]
#   bash check_single_source_of_truth.sh --strict [target_dir]

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"

TODO_PATTERN='\b(TodoWrite|TodoRead|TodoList|Todo[A-Z][A-Za-z0-9_]*)\b'
TASK_PATTERN='\b(ViewTasks?|AddTask|UpdateTask|ReorganizeTasks?|TaskDone|TaskList|TaskManagement)\b'

TMP_RS=$(create_tmpfile)
list_rs_files "${TARGET_DIR}" \
  | { grep -vE '(/tests/|/test_|_test\.rs$)' || true; } \
  > "${TMP_RS}"

if [[ ! -s "${TMP_RS}" ]]; then
  echo "No Rust source files found."
  exit 0
fi

TODO_HITS=$(while IFS= read -r f; do
  [[ -f "${f}" ]] || continue
  grep -nE "${TODO_PATTERN}" "${f}" 2>/dev/null | awk -v file="${f}" '{print file ":" $0}' || true
done < "${TMP_RS}" | head -20)

TASK_HITS=$(while IFS= read -r f; do
  [[ -f "${f}" ]] || continue
  grep -nE "${TASK_PATTERN}" "${f}" 2>/dev/null | awk -v file="${f}" '{print file ":" $0}' || true
done < "${TMP_RS}" | head -20)

STORE_HITS=$(while IFS= read -r f; do
  [[ -f "${f}" ]] || continue
  awk -v file="${f}" '
    {
      line=tolower($0)
      if (line !~ /(task|todo)/) next
      if (line ~ /static[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/) {
        name = $0
        sub(/^.*static[[:space:]]+/, "", name)
        sub(/[^A-Za-z0-9_].*$/, "", name)
        if (name != "")
          printf "%s %s:%d\n", name, file, NR
      } else if (line ~ /:[[:space:]]*(arc<)?(mutex|rwlock|dashmap|hashmap|btreemap|vec)/) {
        name = $0
        sub(/^[[:space:]]*/, "", name)
        sub(/[[:space:]]*:.*$/, "", name)
        if (name ~ /^[A-Za-z_][A-Za-z0-9_]*$/)
          printf "%s %s:%d\n", name, file, NR
      }
    }
  ' "${f}" 2>/dev/null || true
done < "${TMP_RS}" | sort -u)

FOUND=0

if [[ -n "${TODO_HITS}" && -n "${TASK_HITS}" ]]; then
  echo "[RS-12] Potential dual task systems detected (Todo* + TaskManagement*)."
  echo "  Todo-family references:"
  while IFS= read -r line; do
    [[ -n "${line}" ]] && echo "    - ${line}"
  done <<< "${TODO_HITS}"
  echo "  Task-management references:"
  while IFS= read -r line; do
    [[ -n "${line}" ]] && echo "    - ${line}"
  done <<< "${TASK_HITS}"
  echo "  修复：收敛到单一任务系统（单工具族 + 单状态源），避免并行双轨。"
  echo
  FOUND=$((FOUND + 1))
fi

STORE_COUNT=$(echo "${STORE_HITS}" | sed '/^$/d' | wc -l | tr -d ' ')
if [[ "${STORE_COUNT}" -gt 1 ]]; then
  echo "[RS-12] Multiple task/todo state stores detected (${STORE_COUNT})."
  while IFS= read -r line; do
    [[ -n "${line}" ]] && echo "    - ${line}"
  done <<< "${STORE_HITS}"
  echo "  风险：任务状态可能分散在多个容器，形成非单一事实源。"
  echo "  修复：提取统一 state/repository，所有任务动作只写入一个状态入口。"
  echo
  FOUND=$((FOUND + 1))
fi

if [[ "${FOUND}" -eq 0 ]]; then
  echo "No single-source-of-truth issues detected."
  exit 0
fi

echo "Found ${FOUND} potential single-source-of-truth issue(s)."
if [[ "${STRICT}" == true ]]; then
  exit 1
fi
