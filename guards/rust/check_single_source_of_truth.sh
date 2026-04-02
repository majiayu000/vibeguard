#!/usr/bin/env bash
# VibeGuard Rust Guard: Detect mission system single source of truth corruption (RS-12)
#
# Target question:
# - Todo* and TaskManagement* two tool families coexist and appear in the tool registration link at the same time
# - There are too many global state containers related to task/todo, which may cause the state source to be split.
#
# Usage:
#   bash check_single_source_of_truth.sh [target_dir]
#   bash check_single_source_of_truth.sh --strict [target_dir]

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"

# Fix RS-12: only match Claude Code-specific tool names, not generic data structures
# like TodoList, TodoItem, TodoTask which are common application types.
TODO_PATTERN='\b(TodoWrite|TodoRead)\b'
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
  echo "Fix: Convergence to a single task system (single tool family + single state source), avoiding parallel dual rails."
  echo
  FOUND=$((FOUND + 1))
fi

STORE_COUNT=$(echo "${STORE_HITS}" | sed '/^$/d' | wc -l | tr -d ' ')
if [[ "${STORE_COUNT}" -gt 1 ]]; then
  echo "[RS-12] Multiple task/todo state stores detected (${STORE_COUNT})."
  while IFS= read -r line; do
    [[ -n "${line}" ]] && echo "    - ${line}"
  done <<< "${STORE_HITS}"
  echo "Risk: Task status may be scattered across multiple containers, forming a non-single source of truth."
  echo "Fixed: Extract unified state/repository, and only write one state entry for all task actions."
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
