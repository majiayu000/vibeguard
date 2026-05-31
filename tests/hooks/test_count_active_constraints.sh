#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../lib/hook_test_lib.sh"
hook_test_init

TMP_ROOT="$(mktemp -d)"
cleanup_count_active_constraints() {
  rm -rf "${TMP_ROOT}"
}
trap cleanup_count_active_constraints EXIT

COUNTER="${REPO_DIR}/scripts/constraints/count_active_constraints.py"
HOOK="${REPO_DIR}/hooks/count_active_constraints.sh"

hook_no_ci_env=(
  CI=false
  GITHUB_ACTIONS=false
  TRAVIS=false
  CIRCLECI=false
  JENKINS_URL=
  GITLAB_CI=false
  TF_BUILD=false
)

make_home() {
  local home_dir="$1"
  mkdir -p "${home_dir}/.claude/rules"
}

make_repo() {
  local repo_dir="$1"
  mkdir -p "${repo_dir}/.claude/rules" "${repo_dir}/src"
}

header "count_active_constraints.py"

SAFE_HOME="${TMP_ROOT}/home-safe"
SAFE_REPO="${TMP_ROOT}/repo-safe"
make_home "${SAFE_HOME}"
make_repo "${SAFE_REPO}"
cat > "${SAFE_REPO}/AGENTS.md" <<'MD'
# Project Instructions

- Must keep changes small.
- Verify tests before final response.
MD

safe_json="$(python3 "${COUNTER}" --root "${SAFE_REPO}" --home "${SAFE_HOME}" --json)"
assert_contains "${safe_json}" '"status": "ok"' "small context stays within budget"
assert_contains "${safe_json}" '"total": 2' "small context counts normative bullets"

WARN_HOME="${TMP_ROOT}/home-warn"
WARN_REPO="${TMP_ROOT}/repo-warn"
make_home "${WARN_HOME}"
make_repo "${WARN_REPO}"
{
  echo "# Warn"
  for i in $(seq 1 16); do
    echo "- Must satisfy constraint ${i}."
  done
} > "${WARN_REPO}/AGENTS.md"

warn_json="$(python3 "${COUNTER}" --root "${WARN_REPO}" --home "${WARN_HOME}" --json)"
assert_contains "${warn_json}" '"status": "warn"' ">15 constraints returns warning status"

BLOCK_HOME="${TMP_ROOT}/home-block"
BLOCK_REPO="${TMP_ROOT}/repo-block"
make_home "${BLOCK_HOME}"
make_repo "${BLOCK_REPO}"
{
  echo "# Block"
  for i in $(seq 1 31); do
    printf '## U-%02d: Rule %02d\n\nText.\n\n' "${i}" "${i}"
  done
} > "${BLOCK_REPO}/.claude/rules/common.md"

assert_exit_nonzero ">30 constraints can fail strict budget" \
  python3 "${COUNTER}" --root "${BLOCK_REPO}" --home "${BLOCK_HOME}" --fail-on-block

PATH_HOME="${TMP_ROOT}/home-path"
PATH_REPO="${TMP_ROOT}/repo-path"
make_home "${PATH_HOME}"
make_repo "${PATH_REPO}"
cat > "${PATH_REPO}/.claude/rules/python.md" <<'MD'
---
paths: **/*.py
---

# Python Rules

## PY-01: Python-only rule
MD

path_json="$(python3 "${COUNTER}" --root "${PATH_REPO}" --home "${PATH_HOME}" --task-path src/app.py --json)"
assert_contains "${path_json}" '"id": "PY-01"' "path-scoped rule activates for matching task path"
no_path_json="$(python3 "${COUNTER}" --root "${PATH_REPO}" --home "${PATH_HOME}" --task-path README.md --json)"
assert_not_contains "${no_path_json}" '"id": "PY-01"' "path-scoped rule stays unloaded for non-matching task path"

canonical_ids_for_task_path() {
  local task_path="$1"
  python3 "${COUNTER}" --root "${REPO_DIR}" --home "${PATH_HOME}" --include-canonical-rules --task-path "${task_path}" --json \
    | python3 -c 'import json, sys; data = json.load(sys.stdin); print("\n".join(item["id"] for item in data.get("constraints", []) if item.get("id")))'
}

canonical_readme_ids="$(canonical_ids_for_task_path README.md)"
assert_not_contains "${canonical_readme_ids}" "U-11" "data consistency rules stay unloaded for unrelated docs task"
assert_not_contains "${canonical_readme_ids}" "W-18" "eval validation rule stays unloaded for unrelated docs task"

canonical_eval_ids="$(canonical_ids_for_task_path evals/agent_eval.py)"
assert_contains "${canonical_eval_ids}" "W-18" "eval validation rule activates for eval task path"

canonical_python_ids="$(canonical_ids_for_task_path src/main.py)"
assert_contains "${canonical_python_ids}" "U-11" "data consistency rules activate for source task path"
assert_not_contains "${canonical_python_ids}" "W-18" "eval validation rule stays scoped away from ordinary source path"

GC_HOME="${TMP_ROOT}/home-gc"
GC_REPO="${TMP_ROOT}/repo-gc"
make_home "${GC_HOME}"
make_repo "${GC_REPO}"
cat > "${GC_REPO}/.claude/rules/common.md" <<'MD'
# Rules

## U-10: Seen rule

## U-11: Unseen rule
MD
mkdir -p "${GC_HOME}/.vibeguard"
printf '{"reason":"U-10 fired"}\n' > "${GC_HOME}/.vibeguard/events.jsonl"
gc_out="$(python3 "${COUNTER}" --root "${GC_REPO}" --home "${GC_HOME}" --gc-report)"
assert_contains "${gc_out}" "U-11" "gc report lists low-frequency rule candidate"
assert_not_contains "${gc_out}" "U-10 (" "gc report excludes recently observed rule"

header "count_active_constraints hook"

hook_warn_out="$(env "${hook_no_ci_env[@]}" HOME="${WARN_HOME}" VIBEGUARD_PROJECT_ROOT="${WARN_REPO}" VIBEGUARD_LOG_DIR="${TMP_ROOT}/logs-warn" bash "${HOOK}" <<'JSON'
{"hook_event_name":"SessionStart"}
JSON
)"
assert_contains "${hook_warn_out}" "hookSpecificOutput" "hook emits additional context on warning"
assert_contains "${hook_warn_out}" "effective task constraints=16" "hook warning includes constraint count"

hook_block_err="${TMP_ROOT}/hook-block.err"
set +e
env "${hook_no_ci_env[@]}" HOME="${BLOCK_HOME}" VIBEGUARD_PROJECT_ROOT="${BLOCK_REPO}" VIBEGUARD_LOG_DIR="${TMP_ROOT}/logs-block" bash "${HOOK}" <<'JSON' 2>"${hook_block_err}" >/dev/null
{"hook_event_name":"SessionStart"}
JSON
hook_block_rc=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ "${hook_block_rc}" -eq 2 ]] && grep -qF "[BLOCKED] VIBEGUARD U-32 block" "${hook_block_err}"; then
  green "hook blocks when strict budget exceeds 30"
  PASS=$((PASS + 1))
else
  red "hook blocks when strict budget exceeds 30"
  FAIL=$((FAIL + 1))
fi

hook_test_finish
