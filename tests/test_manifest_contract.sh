#!/usr/bin/env bash
# VibeGuard manifest contract regression tests
#
# Usage: bash tests/test_manifest_contract.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST_HELPER="${REPO_DIR}/scripts/lib/vibeguard_manifest.py"
CODEX_CONFIG_HELPER="${REPO_DIR}/scripts/lib/codex_config_toml.py"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit code: $?)"
    FAIL=$((FAIL + 1))
  fi
}

assert_cmd_fail() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (expected failure)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF "$unexpected"; then
    red "$desc (unexpected content: $unexpected)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "helper syntax"
assert_cmd "manifest helper syntax is correct" python3 -m py_compile "${MANIFEST_HELPER}"
assert_cmd "codex config helper syntax is correct" python3 -m py_compile "${CODEX_CONFIG_HELPER}"

header "manifest contract"
assert_cmd "manifest contract validates" python3 "${MANIFEST_HELPER}" validate
profiles_out="$(python3 "${MANIFEST_HELPER}" profile-names)"
assert_contains "${profiles_out}" "core" "profile list contains core"
assert_contains "${profiles_out}" "full" "profile list contains full"
rules_out="$(python3 "${MANIFEST_HELPER}" rule-ids --source canonical --scope common)"
assert_contains "${rules_out}" "W-17" "canonical common rule ids include W-17"
assert_contains "${rules_out}" "U-32" "canonical common rule ids include U-32"
reference_rules_out="$(python3 "${MANIFEST_HELPER}" rule-ids --source reference)"
assert_contains "${reference_rules_out}" "TASTE-ANSI" "reference rule ids include TASTE-prefixed rules"
claude_skills_out="$(python3 "${MANIFEST_HELPER}" skill-links --target "~/.claude/skills/")"
assert_contains "${claude_skills_out}" $'skills/vibeguard\tvibeguard' "manifest declares Claude vibeguard skill link"
assert_contains "${claude_skills_out}" $'workflows/auto-optimize\tauto-optimize' "manifest declares Claude auto-optimize skill link"
codex_skills_out="$(python3 "${MANIFEST_HELPER}" skill-links --target "~/.codex/skills/")"
assert_contains "${codex_skills_out}" $'workflows/plan-flow\tplan-flow' "manifest declares Codex workflow skill links"
assert_contains "${codex_skills_out}" $'skills/trajectory-review\ttrajectory-review' "manifest declares Codex core skill links"
BAD_MANIFEST="${TMP_DIR}/bad-install-modules.json"
printf '{"modules": {}}\n' > "${BAD_MANIFEST}"
assert_cmd_fail "skill-links rejects malformed modules shape" python3 "${MANIFEST_HELPER}" skill-links --manifest-file "${BAD_MANIFEST}" --target "~/.claude/skills/"
BAD_SKILL_PATHS_MANIFEST="${TMP_DIR}/bad-skill-paths-install-modules.json"
cat > "${BAD_SKILL_PATHS_MANIFEST}" <<'JSON'
{
  "profiles": {},
  "modules": [
    {
      "id": "bad-skill-module",
      "kind": "skills",
      "target": "~/.claude/skills/",
      "paths": {}
    }
  ]
}
JSON
bad_skill_paths_validate_out="$(python3 "${MANIFEST_HELPER}" validate --manifest-file "${BAD_SKILL_PATHS_MANIFEST}" 2>&1 || true)"
assert_contains "${bad_skill_paths_validate_out}" "module bad-skill-module: paths must be a list" "manifest validation reports malformed skill paths"
assert_not_contains "${bad_skill_paths_validate_out}" "Traceback" "manifest validation reports malformed skill paths without traceback"

ESCAPING_SKILL_PATH_MANIFEST="${TMP_DIR}/escaping-skill-path-install-modules.json"
cat > "${ESCAPING_SKILL_PATH_MANIFEST}" <<'JSON'
{
  "profiles": {},
  "modules": [
    {
      "id": "escaping-skill-module",
      "kind": "skills",
      "target": "~/.claude/skills/",
      "paths": ["../external/skill"]
    }
  ]
}
JSON
assert_cmd_fail "skill-links rejects repo-escaping skill paths" python3 "${MANIFEST_HELPER}" skill-links --manifest-file "${ESCAPING_SKILL_PATH_MANIFEST}" --target "~/.claude/skills/"
escaping_skill_validate_out="$(python3 "${MANIFEST_HELPER}" validate --manifest-file "${ESCAPING_SKILL_PATH_MANIFEST}" 2>&1 || true)"
assert_contains "${escaping_skill_validate_out}" "module escaping-skill-module: skill path must not contain '..': ../external/skill" "manifest validation reports repo-escaping skill paths"
assert_not_contains "${escaping_skill_validate_out}" "Traceback" "manifest validation reports repo-escaping skill paths without traceback"

ABSOLUTE_SKILL_PATH_MANIFEST="${TMP_DIR}/absolute-skill-path-install-modules.json"
cat > "${ABSOLUTE_SKILL_PATH_MANIFEST}" <<'JSON'
{
  "profiles": {},
  "modules": [
    {
      "id": "absolute-skill-module",
      "kind": "skills",
      "target": "~/.claude/skills/",
      "paths": ["/tmp/skill"]
    }
  ]
}
JSON
assert_cmd_fail "skill-links rejects absolute skill paths" python3 "${MANIFEST_HELPER}" skill-links --manifest-file "${ABSOLUTE_SKILL_PATH_MANIFEST}" --target "~/.claude/skills/"
absolute_skill_validate_out="$(python3 "${MANIFEST_HELPER}" validate --manifest-file "${ABSOLUTE_SKILL_PATH_MANIFEST}" 2>&1 || true)"
assert_contains "${absolute_skill_validate_out}" "module absolute-skill-module: skill path must be repo-relative: /tmp/skill" "manifest validation reports absolute skill paths"
assert_not_contains "${absolute_skill_validate_out}" "Traceback" "manifest validation reports absolute skill paths without traceback"

header "routing contract"
ROUTING_CONTRACT="${REPO_DIR}/workflows/references/routing-contract.md"
DELEGATION_CONTRACT="${REPO_DIR}/workflows/references/delegation-contract.md"
assert_cmd "canonical routing contract exists" test -f "${ROUTING_CONTRACT}"
assert_cmd "routing contract includes execute_direct" grep -qF "execute_direct" "${ROUTING_CONTRACT}"
assert_cmd "routing contract includes plan_first" grep -qF "plan_first" "${ROUTING_CONTRACT}"
assert_cmd "routing contract includes clarify_first" grep -qF "clarify_first" "${ROUTING_CONTRACT}"
assert_cmd "routing contract requires handoff fields" bash -c "for key in mode artifacts verification_owner stop_conditions lane_map; do grep -qF \"\$key\" '${ROUTING_CONTRACT}' || exit 1; done"
assert_cmd "routing surfaces reference canonical contract" bash -c "for file in '${REPO_DIR}/README.md' '${REPO_DIR}/agents/dispatcher.md' '${REPO_DIR}/workflows/fixflow/SKILL.md' '${REPO_DIR}/workflows/plan-flow/SKILL.md' '${REPO_DIR}/workflows/plan-mode/SKILL.md' '${REPO_DIR}/workflows/auto-optimize/SKILL.md' '${REPO_DIR}/workflows/references/delivery-base.md' '${REPO_DIR}/workflows/plan-flow/references/execplan-integration.md' '${REPO_DIR}/docs/command-schemas.md' '${REPO_DIR}/docs/CLAUDE.md.example' '${REPO_DIR}/docs/README_CN.md' '${REPO_DIR}/claude-md/vibeguard-rules.md' '${REPO_DIR}/templates/AGENTS.md'; do grep -qF 'routing-contract.md' \"\$file\" || exit 1; done"
assert_cmd "canonical delegation contract exists" test -f "${DELEGATION_CONTRACT}"
assert_cmd "delegation contract defines assignment fields" bash -c "for key in task_slice allowed_files forbidden_files authority required_evidence blocker_conditions integration_owner; do grep -qF \"\$key\" '${DELEGATION_CONTRACT}' || exit 1; done"
assert_cmd "delegation contract defines staged team pipeline" bash -c "for stage in solo delegate_readonly team_plan team_exec team_verify fix_loop; do grep -qF \"\$stage\" '${DELEGATION_CONTRACT}' || exit 1; done"
assert_cmd "delegation consumers reference canonical contract" bash -c "for file in '${REPO_DIR}/README.md' '${REPO_DIR}/agents/dispatcher.md' '${REPO_DIR}/workflows/fixflow/SKILL.md' '${REPO_DIR}/workflows/plan-flow/SKILL.md' '${REPO_DIR}/workflows/plan-mode/SKILL.md' '${REPO_DIR}/workflows/auto-optimize/SKILL.md' '${REPO_DIR}/workflows/references/routing-contract.md' '${REPO_DIR}/workflows/references/delivery-base.md' '${REPO_DIR}/workflows/plan-flow/references/execplan-integration.md' '${REPO_DIR}/docs/command-schemas.md' '${REPO_DIR}/docs/CLAUDE.md.example' '${REPO_DIR}/docs/openai-codex-best-practices.md' '${REPO_DIR}/docs/README_CN.md'; do grep -qF 'delegation-contract.md' \"\$file\" || exit 1; done"

header "codex config helper"
CONFIG_FILE="${TMP_DIR}/config.toml"
enable_out="$(python3 "${CODEX_CONFIG_HELPER}" enable-codex-hooks --config-file "${CONFIG_FILE}")"
assert_contains "${enable_out}" "CHANGED" "enable-codex-hooks creates config when missing"
assert_cmd "enable-codex-hooks writes codex_hooks = true" grep -Eq '^codex_hooks[[:space:]]*=[[:space:]]*true$' "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<'TOML'
[features]
codex_hooks_beta = false
foo = true
TOML
enable_prefixed_out="$(python3 "${CODEX_CONFIG_HELPER}" enable-codex-hooks --config-file "${CONFIG_FILE}")"
assert_contains "${enable_prefixed_out}" "CHANGED" "enable-codex-hooks adds canonical key when only prefixed keys exist"
assert_cmd "enable-codex-hooks preserves prefixed feature keys" grep -Eq '^codex_hooks_beta[[:space:]]*=[[:space:]]*false$' "${CONFIG_FILE}"
assert_cmd "enable-codex-hooks adds exact codex_hooks key" grep -Eq '^codex_hooks[[:space:]]*=[[:space:]]*true$' "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<'TOML'
[features] # user comment
codex_hooks_beta = false
TOML
enable_commented_out="$(python3 "${CODEX_CONFIG_HELPER}" enable-codex-hooks --config-file "${CONFIG_FILE}")"
assert_contains "${enable_commented_out}" "CHANGED" "enable-codex-hooks recognizes commented features table"
assert_cmd "enable-codex-hooks does not append duplicate commented features table" bash -c "test \$(grep -Ec '^\\[features\\]' '${CONFIG_FILE}') -eq 1"
assert_cmd "enable-codex-hooks adds exact key under commented features table" grep -Eq '^codex_hooks[[:space:]]*=[[:space:]]*true$' "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<'TOML'
[features]
foo = true

[mcp_servers.vibeguard] # legacy comment
command = "node"
args = ["/legacy/mcp-server/dist/index.js"]

[mcp_servers.vibeguard.env]
VIBEGUARD_MODE = "legacy"

[mcp_servers.vibeguard.env.deep]
NESTED = "true"

[other]
value = 1
TOML
remove_out="$(python3 "${CODEX_CONFIG_HELPER}" remove-legacy-vibeguard-mcp --config-file "${CONFIG_FILE}")"
assert_contains "${remove_out}" "CHANGED" "remove-legacy-vibeguard-mcp reports change"
assert_cmd "legacy vibeguard mcp tables removed recursively" bash -c "! grep -qE '^\[mcp_servers\\.vibeguard([.]|\\])' '${CONFIG_FILE}'"
assert_cmd "non-legacy tables remain after recursive cleanup" grep -Eq '^\[other\]$' "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<'TOML'
[features]
codex_hooks = true
TOML
check_ok_out="$(python3 "${CODEX_CONFIG_HELPER}" check-codex-hooks --config-file "${CONFIG_FILE}")"
assert_contains "${check_ok_out}" "OK" "check-codex-hooks accepts valid TOML with feature enabled"

cat > "${CONFIG_FILE}" <<'TOML'
[features]
codex_hooks = true
broken = [
TOML
check_invalid_out="$(python3 "${CODEX_CONFIG_HELPER}" check-codex-hooks --config-file "${CONFIG_FILE}" || true)"
assert_contains "${check_invalid_out}" "INVALID" "check-codex-hooks rejects malformed TOML"

python3 - <<'PY' "${CONFIG_FILE}"
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'[features]\ncodex_hooks = true\n\xff')
PY
check_invalid_utf8_out="$(python3 "${CODEX_CONFIG_HELPER}" check-codex-hooks --config-file "${CONFIG_FILE}" || true)"
assert_contains "${check_invalid_utf8_out}" "INVALID" "check-codex-hooks rejects invalid UTF-8"

header "doc freshness installed drift"
EMPTY_HOME="${TMP_DIR}/empty-home"
mkdir -p "${EMPTY_HOME}/.claude/rules/vibeguard"
installed_out="$(HOME="${EMPTY_HOME}" bash "${REPO_DIR}/scripts/verify/doc-freshness-check.sh" --installed)"
assert_contains "${installed_out}" "Installed rule ids: 0" "installed drift reports empty installed rule set"
assert_contains "${installed_out}" "Installed-vs-repo rule drift" "installed drift lists missing canonical rules even when installed set is empty"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
