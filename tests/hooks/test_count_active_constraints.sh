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
RUNTIME_BIN="${VIBEGUARD_RUNTIME:-${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime}"
if [[ ! -x "${RUNTIME_BIN}" ]]; then
  cargo build --quiet --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml"
fi

hook_no_ci_env=(
  CI=false
  GITHUB_ACTIONS=false
  TRAVIS=false
  CIRCLECI=false
  JENKINS_URL=
  GITLAB_CI=false
  TF_BUILD=false
  VIBEGUARD_HOME=
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
    rule_id=$((i + 100))
    printf '## U-%d: Rule %d\n\nText.\n\n' "${rule_id}" "${rule_id}"
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

HOST_HOME="${TMP_ROOT}/home-host"
HOST_REPO="${TMP_ROOT}/repo-host"
make_home "${HOST_HOME}"
make_repo "${HOST_REPO}"
mkdir -p "${HOST_HOME}/.codex"
cat > "${HOST_HOME}/.claude/CLAUDE.md" <<'MD'
# Claude Global

- Must keep Claude global guidance.
MD
cat > "${HOST_HOME}/.codex/AGENTS.md" <<'MD'
# Codex Global

- Must not count Codex global guidance.
MD
host_claude_json="$(python3 "${COUNTER}" --root "${HOST_REPO}" --home "${HOST_HOME}" --host claude --json)"
assert_contains "${host_claude_json}" '"total": 1' "Claude host scope counts only Claude global guidance"
assert_not_contains "${host_claude_json}" "Codex global guidance" "Claude host scope excludes Codex global guidance"
host_all_json="$(python3 "${COUNTER}" --root "${HOST_REPO}" --home "${HOST_HOME}" --json)"
assert_contains "${host_all_json}" '"total": 2' "default host scope preserves all global guidance"

CUSTOM_CODEX_HOME="${TMP_ROOT}/custom-codex-home"
mkdir -p "${CUSTOM_CODEX_HOME}/rules" "${HOST_REPO}/.claude/rules"
cat > "${CUSTOM_CODEX_HOME}/AGENTS.md" <<'MD'
# Custom Codex Global

- Must count configured Codex guidance.
MD
cat > "${CUSTOM_CODEX_HOME}/rules/decoy.md" <<'MD'
# Unsupported Codex Native Rule

- Must not count unsupported Codex native rules.
MD
cat > "${HOST_REPO}/AGENTS.md" <<'MD'
# Shared Project

- Must count project AGENTS guidance.
MD
cat > "${HOST_REPO}/CLAUDE.md" <<'MD'
# Claude Project

- Must not count Claude project guidance.
MD
cat > "${HOST_REPO}/.claude/rules/claude.md" <<'MD'
# Claude Project Rule

- Must not count Claude project rules.
MD
custom_codex_json="$(env CODEX_HOME="${CUSTOM_CODEX_HOME}" python3 "${COUNTER}" --root "${HOST_REPO}" --home "${HOST_HOME}" --host codex --json)"
assert_contains "${custom_codex_json}" '"total": 2' "Codex scope counts configured CODEX_HOME plus project AGENTS only"
assert_contains "${custom_codex_json}" "configured Codex guidance" "Codex scope honors CODEX_HOME"
assert_not_contains "${custom_codex_json}" "Claude project" "Codex scope excludes Claude-only project instructions and rules"
assert_not_contains "${custom_codex_json}" "Codex global guidance" "configured CODEX_HOME replaces the fallback ~/.codex source"
assert_not_contains "${custom_codex_json}" "unsupported Codex native rules" "Codex scope excludes unsupported native rule paths"

mkdir -p "${HOST_REPO}/packages/api/src" "${HOST_REPO}/packages/web"
cat > "${HOST_REPO}/packages/AGENTS.md" <<'MD'
- Must count parent package guidance.
MD
cat > "${HOST_REPO}/packages/api/AGENTS.md" <<'MD'
- Must not count overridden API fallback guidance.
MD
cat > "${HOST_REPO}/packages/api/AGENTS.override.md" <<'MD'
- Must count nested API override guidance.
MD
cat > "${HOST_REPO}/packages/web/AGENTS.md" <<'MD'
- Must not count sibling guidance.
MD
nested_codex_json="$(env CODEX_HOME="${CUSTOM_CODEX_HOME}" python3 "${COUNTER}" --root "${HOST_REPO}" --home "${HOST_HOME}" --host codex --task-path packages/api/src/lib.rs --json)"
assert_contains "${nested_codex_json}" '"total": 4' "Codex scope counts root and applicable nested AGENTS files"
assert_contains "${nested_codex_json}" "parent package guidance" "Codex scope counts parent AGENTS guidance"
assert_contains "${nested_codex_json}" "nested API override guidance" "Codex scope prefers nearest AGENTS override guidance"
assert_not_contains "${nested_codex_json}" "overridden API fallback guidance" "Codex scope excludes overridden fallback AGENTS guidance"
assert_not_contains "${nested_codex_json}" "sibling guidance" "Codex scope excludes sibling AGENTS guidance"
nested_codex_runtime_json="$(env CODEX_HOME="${CUSTOM_CODEX_HOME}" "${RUNTIME_BIN}" active-constraints --root "${HOST_REPO}" --home "${HOST_HOME}" --host codex --task-path packages/api/src/lib.rs --json)"
assert_contains "${nested_codex_runtime_json}" '"total": 4' "production counter matches nested Codex instruction discovery"
mkdir -p "${TMP_ROOT}/outside"
cat > "${TMP_ROOT}/outside/AGENTS.md" <<'MD'
- Must not count an instruction outside the repository.
MD
outside_codex_json="$(env CODEX_HOME="${CUSTOM_CODEX_HOME}" python3 "${COUNTER}" --root "${HOST_REPO}" --home "${HOST_HOME}" --host codex --task-path ../outside/new.rs --json)"
assert_contains "${outside_codex_json}" '"total": 2' "Codex scope rejects unresolved task paths outside the repository"
assert_not_contains "${outside_codex_json}" "outside the repository" "Codex scope excludes external AGENTS guidance"
outside_codex_runtime_json="$(env CODEX_HOME="${CUSTOM_CODEX_HOME}" "${RUNTIME_BIN}" active-constraints --root "${HOST_REPO}" --home "${HOST_HOME}" --host codex --task-path ../outside/new.rs --json)"
assert_contains "${outside_codex_runtime_json}" '"total": 2' "production counter rejects unresolved external task paths"
assert_not_contains "${outside_codex_runtime_json}" "outside the repository" "production counter excludes external AGENTS guidance"
CORE_ROW_REPO="${TMP_ROOT}/repo-core-row-dedupe"
CORE_ROW_HOME="${TMP_ROOT}/home-core-row-dedupe"
make_home "${CORE_ROW_HOME}"
make_repo "${CORE_ROW_REPO}"
cat > "${CORE_ROW_HOME}/.claude/CLAUDE.md" <<'MD'
## Core contract

| Area | Default |
|---|---|
| Scope | Keep changes focused. |
MD
cat > "${CORE_ROW_REPO}/AGENTS.md" <<'MD'
## Core contract

| Area | Default |
|---|---|
| Scope | Do not edit generated files. |

## Rule inventory

| ID | State |
|---|---|
| U-01 | disabled |
MD
core_row_json="$(python3 "${COUNTER}" --root "${CORE_ROW_REPO}" --home "${CORE_ROW_HOME}" --host claude --json)"
assert_contains "${core_row_json}" '"total": 2' "same-area core rows with different requirements remain distinct"
assert_not_contains "${core_row_json}" '"id": "U-01"' "ordinary rule inventories outside the generated marker are ignored"

EQUIVALENT_REPO="${TMP_ROOT}/repo-core-equivalents"
EQUIVALENT_HOME="${TMP_ROOT}/home-core-equivalents"
make_home "${EQUIVALENT_HOME}"
make_repo "${EQUIVALENT_REPO}"
cat > "${EQUIVALENT_REPO}/AGENTS.md" <<'MD'
## Core contract

| Area | Default |
|---|---|
| Errors | User-visible missing data, malformed input, or wrong output must fail clearly. |
| Scope | Make the smallest requested change; do not add adjacent improvements. |
| Safety | Never expose secrets, add hidden AI attribution, force-push, or weaken tests. |
| Preservation | Preserve unmanaged content in high-context files, settings, and hooks. |
| Verification | Run a fresh, focused project command before claiming completion. |

## Key detailed rules

<!-- vibeguard-generated-compact-rules:start -->
| ID | Severity | Rule |
|---|---|---|
| SEC-02 | Strict | Secrets. |
| SEC-13 | Strict | Preservation. |
| U-04 | Strict | Scope. |
| U-08 | Strict | Verification. |
| U-17 | Strict | Errors. |
| U-29 | Strict | Errors. |
| W-03 | Strict | Verification. |
| W-12 | Strict | Safety. |
| W-16 | Strict | Verification. |
<!-- vibeguard-generated-compact-rules:end -->
MD
equivalent_json="$(python3 "${COUNTER}" --root "${EQUIVALENT_REPO}" --home "${EQUIVALENT_HOME}" --host claude --json)"
assert_contains "${equivalent_json}" '"total": 11' "Python counter keeps distinct detailed rules while deduplicating exact core equivalents"
equivalent_ids="$(printf '%s' "${equivalent_json}" | python3 -c 'import json, sys; print(",".join(item["id"] for item in json.load(sys.stdin)["constraints"] if item["id"]))')"
assert_exit_zero "Python counter retains every detailed constraint ID" test "${equivalent_ids}" = "SEC-02,SEC-13,U-04,U-08,U-17,U-29,W-03,W-12,W-16"
equivalent_runtime_json="$("${RUNTIME_BIN}" active-constraints --root "${EQUIVALENT_REPO}" --home "${EQUIVALENT_HOME}" --host claude --json)"
assert_contains "${equivalent_runtime_json}" '"total": 11' "production counter matches exact shared-core equivalence"

canonical_ids_for_task_path() {
  local task_path="$1"
  python3 "${COUNTER}" --root "${REPO_DIR}" --home "${PATH_HOME}" --include-canonical-rules --task-path "${task_path}" --json \
    | python3 -c 'import json, sys; data = json.load(sys.stdin); print("\n".join(item["id"] for item in data.get("constraints", []) if item.get("id")))'
}

canonical_readme_ids="$(canonical_ids_for_task_path README.md)"
assert_not_contains "${canonical_readme_ids}" "U-11" "data consistency rules stay unloaded for unrelated docs task"
assert_not_contains "${canonical_readme_ids}" "W-18" "eval validation rule stays unloaded for unrelated docs task"

canonical_eval_ids="$(canonical_ids_for_task_path evals/runner.py)"
assert_contains "${canonical_eval_ids}" "W-18" "eval validation rule activates for eval directory task path"

canonical_eval_manifest_ids="$(canonical_ids_for_task_path evals/package.json)"
assert_contains "${canonical_eval_manifest_ids}" "W-18" "eval validation rule activates for eval-scoped dependency manifest"

canonical_python_ids="$(canonical_ids_for_task_path src/main.py)"
assert_contains "${canonical_python_ids}" "U-11" "data consistency rules activate for source task path"
assert_not_contains "${canonical_python_ids}" "W-18" "eval validation rule stays scoped away from ordinary source path"

for ordinary_manifest_path in package.json pyproject.toml Cargo.toml go.mod; do
  ordinary_manifest_ids="$(canonical_ids_for_task_path "${ordinary_manifest_path}")"
  assert_not_contains "${ordinary_manifest_ids}" "W-18" "eval validation rule stays scoped away from ordinary ${ordinary_manifest_path}"
done

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

# GH-683: without a strict profile, exceeding the block budget must surface as
# injected context (exit 0), not a failed hook — core/full users still see it.
hook_softblock_out="$(env "${hook_no_ci_env[@]}" HOME="${BLOCK_HOME}" VIBEGUARD_PROJECT_ROOT="${BLOCK_REPO}" VIBEGUARD_LOG_DIR="${TMP_ROOT}/logs-softblock" bash "${HOOK}" <<'JSON'
{"hook_event_name":"SessionStart"}
JSON
)"
assert_contains "${hook_softblock_out}" "hookSpecificOutput" "non-strict profile surfaces block budget as context"
assert_contains "${hook_softblock_out}" "VIBEGUARD U-32 block" "non-strict block context names the U-32 status"

mkdir -p "${BLOCK_HOME}/.vibeguard"
printf '{\n  "profile": "strict"\n}\n' > "${BLOCK_HOME}/.vibeguard/install-state.json"

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

# Explicit env override still wins over the installed profile.
hook_override_out="$(env "${hook_no_ci_env[@]}" HOME="${BLOCK_HOME}" VIBEGUARD_U32_STRICT=0 VIBEGUARD_PROJECT_ROOT="${BLOCK_REPO}" VIBEGUARD_LOG_DIR="${TMP_ROOT}/logs-override" bash "${HOOK}" <<'JSON'
{"hook_event_name":"SessionStart"}
JSON
)"
assert_contains "${hook_override_out}" "hookSpecificOutput" "VIBEGUARD_U32_STRICT=0 downgrades strict block to context"

header "GH-541 rule-delivery budget (compact core default vs full-tree opt-in)"
# The default (core/minimal) Claude profile injects only the shared compact core
# plus Claude host guidance into ~/.claude/CLAUDE.md; the full rules/claude-rules
# tree is opt-in under full/strict. This asserts the actual production content:
# semantic deduplication keeps the compact core at the 15-constraint advisory
# boundary, while the full common/ tree — the payload the default profile must
# NOT front-inject — still exceeds the block threshold.
# See scripts/setup/targets/claude-home.sh Step 5.5.

CLAUDE_COMPACT_SRC="${REPO_DIR}/claude-md/vibeguard-claude-rules.md"
CODEX_COMPACT_SRC="${REPO_DIR}/claude-md/vibeguard-codex-rules.md"
TOTAL=$((TOTAL + 1))
if [[ -f "${CLAUDE_COMPACT_SRC}" && -f "${CODEX_COMPACT_SRC}" ]]; then
  green "rendered host payloads are present"
  PASS=$((PASS + 1))

  CLAUDE_CORE_HOME="${TMP_ROOT}/home-gh541-claude-core"
  CLAUDE_CORE_REPO="${TMP_ROOT}/repo-gh541-claude-core"
  make_home "${CLAUDE_CORE_HOME}"
  make_repo "${CLAUDE_CORE_REPO}"
  cp "${CLAUDE_COMPACT_SRC}" "${CLAUDE_CORE_HOME}/.claude/CLAUDE.md"
  claude_core_json="$(python3 "${COUNTER}" --root "${CLAUDE_CORE_REPO}" --home "${CLAUDE_CORE_HOME}" --host claude --json)"
  assert_contains "${claude_core_json}" '"total": 19' "Python counter reports the exact Claude payload budget"
  assert_contains "${claude_core_json}" '"status": "warn"' "Claude payload truthfully reports its advisory budget status"
  claude_compact_ids="$(printf '%s' "${claude_core_json}" | python3 -c 'import json, sys; print(",".join(item["id"] for item in json.load(sys.stdin)["constraints"] if item["id"]))')"
  assert_exit_zero "Claude payload retains every compact constraint ID" test "${claude_compact_ids}" = "U-17,U-29,W-02,W-03,W-12,W-16,SEC-01,SEC-02,SEC-11,SEC-13"
  claude_runtime_json="$("${RUNTIME_BIN}" active-constraints --root "${CLAUDE_CORE_REPO}" --home "${CLAUDE_CORE_HOME}" --host claude --json)"
  assert_contains "${claude_runtime_json}" '"total": 19' "production counter matches the exact Claude payload count"

  CODEX_CORE_HOME="${TMP_ROOT}/home-gh541-codex-core"
  CODEX_CORE_REPO="${TMP_ROOT}/repo-gh541-codex-core"
  make_home "${CODEX_CORE_HOME}"
  make_repo "${CODEX_CORE_REPO}"
  mkdir -p "${CODEX_CORE_HOME}/.codex"
  cp "${CODEX_COMPACT_SRC}" "${CODEX_CORE_HOME}/.codex/AGENTS.md"
  codex_core_json="$(python3 "${COUNTER}" --root "${CODEX_CORE_REPO}" --home "${CODEX_CORE_HOME}" --host codex --json)"
  assert_contains "${codex_core_json}" '"total": 19' "Python counter reports the exact Codex payload budget"
  assert_contains "${codex_core_json}" '"status": "warn"' "Codex payload truthfully reports its advisory budget status"
  codex_compact_ids="$(printf '%s' "${codex_core_json}" | python3 -c 'import json, sys; print(",".join(item["id"] for item in json.load(sys.stdin)["constraints"] if item["id"]))')"
  assert_exit_zero "Codex payload retains every compact constraint ID" test "${codex_compact_ids}" = "U-17,U-29,W-02,W-03,W-12,W-16,SEC-01,SEC-02,SEC-11,SEC-13"
  codex_runtime_json="$("${RUNTIME_BIN}" active-constraints --root "${CODEX_CORE_REPO}" --home "${CODEX_CORE_HOME}" --host codex --json)"
  assert_contains "${codex_runtime_json}" '"total": 19' "production counter matches the exact Codex payload count"

  FULL_HOME="${TMP_ROOT}/home-gh541-full"
  FULL_REPO="${TMP_ROOT}/repo-gh541-full"
  make_home "${FULL_HOME}"
  make_repo "${FULL_REPO}"
  mkdir -p "${FULL_HOME}/.claude/rules/vibeguard/common"
  cp "${REPO_DIR}/rules/claude-rules/common/"*.md "${FULL_HOME}/.claude/rules/vibeguard/common/"
  assert_exit_nonzero "full common/ tree exceeds the block budget (must stay opt-in, not default)" \
    python3 "${COUNTER}" --root "${FULL_REPO}" --home "${FULL_HOME}" --fail-on-block
else
  red "rendered host payloads are present"
  FAIL=$((FAIL + 1))
fi

hook_test_finish
