#!/usr/bin/env bash
# VibeGuard manifest contract regression tests
#
# Usage: bash tests/test_manifest_contract.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST_HELPER="${REPO_DIR}/scripts/lib/vibeguard_manifest.py"
CODEX_CONFIG_HELPER="${REPO_DIR}/scripts/lib/codex_config_toml.py"
WORKFLOW_CONTRACT_HELPER="${REPO_DIR}/scripts/lib/workflow_contracts.py"
GUARD_PACKS_HELPER="${REPO_DIR}/scripts/lib/guard_packs.py"

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
assert_cmd "workflow contract helper syntax is correct" python3 -m py_compile "${WORKFLOW_CONTRACT_HELPER}"
assert_cmd "guard packs helper syntax is correct" python3 -m py_compile "${GUARD_PACKS_HELPER}"

header "manifest contract"
assert_cmd "manifest contract validates" python3 "${MANIFEST_HELPER}" validate
profiles_out="$(python3 "${MANIFEST_HELPER}" profile-names)"
assert_contains "${profiles_out}" "core" "profile list contains core"
assert_contains "${profiles_out}" "full" "profile list contains full"
hooks_out="$(python3 "${MANIFEST_HELPER}" hook-names)"
assert_contains "${hooks_out}" "count-active-constraints" "hook list comes from manifest names"
assert_not_contains "${hooks_out}" "count_active_constraints" "hook list does not use script stems"
assert_not_contains "${hooks_out}" "git-pre-push" "git pre-push is tracked but not exposed through disabled_hooks"
assert_not_contains "${hooks_out}" "skills-loader" "manual hooks are not exposed through disabled_hooks"
hooks_table_out="$(python3 "${REPO_DIR}/scripts/lib/hooks_manifest.py" render-doc-table)"
assert_contains "${hooks_table_out}" '`git/pre-push` | git pre-push' "hooks manifest renders git pre-push inventory row"
post_decision_contract_out="$(python3 - "${REPO_DIR}/hooks/manifest.json" <<'PY' 2>&1 || true
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
hooks = {hook["name"]: hook for hook in manifest["hooks"]}
expected = {
    "post-edit-guard": ["pass", "warn", "escalate", "correction"],
    "post-write-guard": ["pass", "warn"],
    "post-build-check": ["pass", "warn", "escalate"],
}
for name, decision_types in expected.items():
    actual = hooks[name]["decision_types"]
    if actual != decision_types:
        print(f"FAIL: {name} decision_types={actual!r}, expected={decision_types!r}")
        raise SystemExit(1)
print("OK: post hook decision_types match actual logging contract")
PY
)"
assert_contains "${post_decision_contract_out}" "OK: post hook decision_types match actual logging contract" "post hook decision_types match actual logging contract"
assert_not_contains "${post_decision_contract_out}" "FAIL:" "post hook decision_types contract reports without failure"
rules_out="$(python3 "${MANIFEST_HELPER}" rule-ids --source canonical --scope common)"
assert_contains "${rules_out}" "W-17" "canonical common rule ids include W-17"
assert_contains "${rules_out}" "U-32" "canonical common rule ids include U-32"
common_paths_out="$(python3 - "${REPO_DIR}/schemas/install-modules.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for module in manifest["modules"]:
    if module.get("id") == "rules-common":
        print("\n".join(module["paths"]))
        break
PY
)"
assert_contains "${common_paths_out}" "rules/claude-rules/common/agent-harness-audit.md" "rules-common installs W-30 rule file"
assert_contains "${common_paths_out}" "rules/claude-rules/common/eval-validation.md" "rules-common installs scoped W-18 rule file"
assert_contains "${common_paths_out}" "rules/claude-rules/common/long-horizon-reliability.md" "rules-common installs W-42 rule file"
rust_rule_links_out="$(python3 "${MANIFEST_HELPER}" rule-links --languages rust)"
assert_contains "${rust_rule_links_out}" $'rules/claude-rules/common/security.md\tcommon/security.md\tcommon' "manifest rule-links include common rules for language filters"
assert_contains "${rust_rule_links_out}" $'rules/claude-rules/rust/quality.md\trust/quality.md\trust' "manifest rule-links include selected Rust rules"
assert_not_contains "${rust_rule_links_out}" "rules/claude-rules/python/quality.md" "manifest rule-links omit unselected Python rules"
go_rule_links_out="$(python3 "${MANIFEST_HELPER}" rule-links --languages golang)"
assert_contains "${go_rule_links_out}" $'rules/claude-rules/golang/quality.md\tgolang/quality.md\tgolang' "manifest rule-links normalize golang language filters"
javascript_rule_links_out="$(python3 "${MANIFEST_HELPER}" rule-links --languages javascript)"
assert_contains "${javascript_rule_links_out}" $'rules/claude-rules/typescript/quality.md\ttypescript/quality.md\ttypescript' "manifest rule-links map JavaScript to TypeScript rules"
assert_not_contains "${javascript_rule_links_out}" "rules/claude-rules/rust/quality.md" "manifest JavaScript rule-links omit unselected Rust rules"
assert_not_contains "${javascript_rule_links_out}" "rules/claude-rules/python/quality.md" "manifest JavaScript rule-links omit unselected Python rules"
assert_not_contains "${javascript_rule_links_out}" "rules/claude-rules/golang/quality.md" "manifest JavaScript rule-links omit unselected Go rules"
javascript_guard_languages_out="$(python3 - "${REPO_DIR}/schemas/install-modules.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for module in manifest["modules"]:
    if module.get("id") == "guards-typescript":
        print("\n".join(module["languages"]))
        break
PY
)"
assert_contains "${javascript_guard_languages_out}" "javascript" "guards-typescript applies to JavaScript projects"
rust_rule_labels_out="$(python3 "${MANIFEST_HELPER}" rule-labels --languages rust)"
assert_contains "${rust_rule_labels_out}" "common" "manifest rule-labels include common"
assert_contains "${rust_rule_labels_out}" "rust" "manifest rule-labels include selected Rust label"
assert_not_contains "${rust_rule_labels_out}" "python" "manifest rule-labels omit unselected Python label"
reference_rules_out="$(python3 "${MANIFEST_HELPER}" rule-ids --source reference)"
assert_contains "${reference_rules_out}" "TASTE-ANSI" "reference rule ids include TASTE-prefixed rules"
claude_skills_out="$(python3 "${MANIFEST_HELPER}" skill-links --target "~/.claude/skills/")"
assert_contains "${claude_skills_out}" $'skills/vibeguard\tvibeguard' "manifest declares Claude vibeguard skill link"
assert_contains "${claude_skills_out}" $'workflows/auto-optimize\tauto-optimize' "manifest declares Claude auto-optimize skill link"
codex_skills_out="$(python3 "${MANIFEST_HELPER}" skill-links --target "~/.codex/skills/")"
assert_contains "${codex_skills_out}" $'workflows/plan-flow\tplan-flow' "manifest declares Codex workflow skill links"
assert_contains "${codex_skills_out}" $'skills/trajectory-review\ttrajectory-review' "manifest declares Codex core skill links"
command_paths_out="$(python3 - "${REPO_DIR}/schemas/install-modules.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for module in manifest["modules"]:
    if module.get("id") == "commands":
        print("\n".join(module["paths"]))
        break
PY
)"
assert_contains "${command_paths_out}" ".claude/commands/vibeguard/" "manifest declares full command path"
assert_contains "${command_paths_out}" ".claude/commands/vg/" "manifest declares vg shortcut command path"
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

BAD_PROJECT_SCHEMA="${TMP_DIR}/bad-vibeguard-project.schema.json"
python3 - "${REPO_DIR}/schemas/vibeguard-project.schema.json" "${BAD_PROJECT_SCHEMA}" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))
enum = data["properties"]["disabled_hooks"]["items"]["enum"]
enum.remove("count-active-constraints")
target.write_text(json.dumps(data), encoding="utf-8")
PY
bad_project_schema_out="$(python3 "${MANIFEST_HELPER}" validate --project-schema "${BAD_PROJECT_SCHEMA}" 2>&1 || true)"
assert_contains "${bad_project_schema_out}" "project schema disabled_hooks enum drift" "manifest validation detects disabled_hooks schema drift"
assert_not_contains "${bad_project_schema_out}" "Traceback" "disabled_hooks schema drift reports without traceback"

BAD_LANGUAGE_SCHEMA="${TMP_DIR}/bad-language-vibeguard-project.schema.json"
python3 - "${REPO_DIR}/schemas/vibeguard-project.schema.json" "${BAD_LANGUAGE_SCHEMA}" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))
enum = data["properties"]["languages"]["items"]["enum"]
enum.remove("javascript")
target.write_text(json.dumps(data), encoding="utf-8")
PY
bad_language_schema_out="$(python3 "${MANIFEST_HELPER}" validate --project-schema "${BAD_LANGUAGE_SCHEMA}" 2>&1 || true)"
assert_contains "${bad_language_schema_out}" "project schema languages enum drift" "manifest validation detects language schema drift"
assert_not_contains "${bad_language_schema_out}" "Traceback" "language schema drift reports without traceback"

BAD_GUARD_SCHEMA="${TMP_DIR}/bad-guard-vibeguard-project.schema.json"
python3 - "${REPO_DIR}/schemas/vibeguard-project.schema.json" "${BAD_GUARD_SCHEMA}" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))
enum = data["properties"]["disabled_guards"]["items"]["enum"]
enum.remove("check_runtime_drift")
target.write_text(json.dumps(data), encoding="utf-8")
PY
bad_guard_schema_out="$(python3 "${MANIFEST_HELPER}" validate --project-schema "${BAD_GUARD_SCHEMA}" 2>&1 || true)"
assert_contains "${bad_guard_schema_out}" "project schema disabled_guards enum drift" "manifest validation detects disabled_guards schema drift"
assert_not_contains "${bad_guard_schema_out}" "Traceback" "disabled_guards schema drift reports without traceback"

BAD_GC_SCHEMA="${TMP_DIR}/bad-gc-vibeguard-project.schema.json"
python3 - "${REPO_DIR}/schemas/vibeguard-project.schema.json" "${BAD_GC_SCHEMA}" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))
data["properties"]["gc"]["properties"].pop("catchup_interval_hours")
target.write_text(json.dumps(data), encoding="utf-8")
PY
bad_gc_schema_out="$(python3 "${MANIFEST_HELPER}" validate --project-schema "${BAD_GC_SCHEMA}" 2>&1 || true)"
assert_contains "${bad_gc_schema_out}" "project schema gc key drift" "manifest validation detects gc schema drift"
assert_not_contains "${bad_gc_schema_out}" "Traceback" "gc schema drift reports without traceback"

BAD_HOOKS_MANIFEST="${TMP_DIR}/bad-hooks-manifest.json"
python3 - "${REPO_DIR}/hooks/manifest.json" "${BAD_HOOKS_MANIFEST}" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))
for hook in data["hooks"]:
    if hook["name"] == "pre-bash-guard":
        hook["install_targets"] = []
        break
target.write_text(json.dumps(data), encoding="utf-8")
PY
bad_hooks_manifest_out="$(python3 "${MANIFEST_HELPER}" validate --hooks-manifest "${BAD_HOOKS_MANIFEST}" 2>&1 || true)"
assert_contains "${bad_hooks_manifest_out}" "hook install target drift for hooks-pre" "manifest validation detects hook install target drift"
assert_not_contains "${bad_hooks_manifest_out}" "Traceback" "hook install target drift reports without traceback"

BAD_CODEX_ENTRIES_HOOKS_MANIFEST="${TMP_DIR}/bad-codex-entries-hooks-manifest.json"
python3 - "${REPO_DIR}/hooks/manifest.json" "${BAD_CODEX_ENTRIES_HOOKS_MANIFEST}" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))
for hook in data["hooks"]:
    if hook["name"] == "pre-bash-guard":
        hook["codex"]["entries"][0]["extra_field"] = True
        break
target.write_text(json.dumps(data), encoding="utf-8")
PY
bad_codex_entries_out="$(python3 "${REPO_DIR}/scripts/lib/hooks_manifest.py" --manifest "${BAD_CODEX_ENTRIES_HOOKS_MANIFEST}" validate 2>&1 || true)"
assert_contains "${bad_codex_entries_out}" "codex.entries[0].extra_field" "hooks manifest schema rejects malformed codex entries"
assert_not_contains "${bad_codex_entries_out}" "Traceback" "malformed codex entries report without traceback"

BAD_GIT_HOOKS_MANIFEST="${TMP_DIR}/bad-git-hooks-manifest.json"
python3 - "${REPO_DIR}/hooks/manifest.json" "${BAD_GIT_HOOKS_MANIFEST}" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))
data["hooks"] = [hook for hook in data["hooks"] if hook["name"] != "git-pre-push"]
target.write_text(json.dumps(data), encoding="utf-8")
PY
bad_git_hooks_manifest_out="$(python3 "${REPO_DIR}/scripts/lib/hooks_manifest.py" --manifest "${BAD_GIT_HOOKS_MANIFEST}" validate 2>&1 || true)"
assert_contains "${bad_git_hooks_manifest_out}" "hooks/git/pre-push missing from hooks manifest" "hooks manifest validation detects missing git pre-push source"
assert_not_contains "${bad_git_hooks_manifest_out}" "Traceback" "git pre-push manifest drift reports without traceback"

BAD_RULE_PATHS_MANIFEST="${TMP_DIR}/bad-rule-paths-install-modules.json"
python3 - "${REPO_DIR}/schemas/install-modules.json" "${BAD_RULE_PATHS_MANIFEST}" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))
for module in data["modules"]:
    if module.get("id") == "rules-common":
        module["paths"] = [
            path for path in module["paths"]
            if path != "rules/claude-rules/common/agent-harness-audit.md"
        ]
        break
target.write_text(json.dumps(data), encoding="utf-8")
PY
bad_rule_paths_validate_out="$(python3 "${MANIFEST_HELPER}" validate --manifest-file "${BAD_RULE_PATHS_MANIFEST}" 2>&1 || true)"
assert_contains "${bad_rule_paths_validate_out}" "rule install path drift" "manifest validation detects missing canonical rule paths"
assert_contains "${bad_rule_paths_validate_out}" "rules/claude-rules/common/agent-harness-audit.md" "manifest rule drift reports the missing rule path"
assert_not_contains "${bad_rule_paths_validate_out}" "Traceback" "manifest rule drift reports without traceback"

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

header "guard pack contract"
assert_cmd "guard pack manifests validate" python3 "${GUARD_PACKS_HELPER}" validate
guard_packs_out="$(python3 "${GUARD_PACKS_HELPER}" list)"
assert_contains "${guard_packs_out}" "safe-bash" "guard pack list contains safe-bash"
safe_bash_explain_out="$(python3 "${GUARD_PACKS_HELPER}" explain safe-bash)"
assert_contains "${safe_bash_explain_out}" "Guard Packs are an adoption layer" "safe-bash explain states adoption boundary"
assert_contains "${safe_bash_explain_out}" "hooks/pre-bash-guard.sh" "safe-bash explain points to source hook"
assert_contains "${safe_bash_explain_out}" "claude-code: native" "safe-bash explain declares Claude Code target"
assert_contains "${safe_bash_explain_out}" "codex: native" "safe-bash explain declares Codex target"
safe_bash_dry_run_out="$(python3 "${GUARD_PACKS_HELPER}" install --target claude-code --pack safe-bash --dry-run)"
assert_contains "${safe_bash_dry_run_out}" "DRY-RUN: install guard pack safe-bash for claude-code" "safe-bash install dry-run reports target"
assert_contains "${safe_bash_dry_run_out}" "Would modify:" "safe-bash dry-run shows planned writes"
assert_contains "${safe_bash_dry_run_out}" "writes=0" "safe-bash dry-run receipt records no writes"
safe_bash_receipt_out="$(python3 "${GUARD_PACKS_HELPER}" receipt safe-bash --target claude-code)"
assert_contains "${safe_bash_receipt_out}" '"rollback_plan": [' "safe-bash receipt includes rollback plan"
assert_contains "${safe_bash_receipt_out}" '"check_ids": [' "safe-bash receipt includes audit check ids"
safe_bash_demo_out="$(python3 "${GUARD_PACKS_HELPER}" demo safe-bash)"
assert_contains "${safe_bash_demo_out}" "No command is executed" "safe-bash demo is side-effect free"
assert_contains "${safe_bash_demo_out}" "Expected decision: block" "safe-bash demo shows block decision"
assert_cmd_fail "guard pack explain rejects unknown pack" python3 "${GUARD_PACKS_HELPER}" explain missing-pack

header "workflow contracts"
assert_cmd "workflow contracts validate from schema registry" python3 "${WORKFLOW_CONTRACT_HELPER}" validate
handoff_required_out="$(python3 "${WORKFLOW_CONTRACT_HELPER}" list-required execution_handoff)"
assert_contains "${handoff_required_out}" "runtime_pinning_snapshot" "execution handoff required keys come from schema"
delegation_required_out="$(python3 "${WORKFLOW_CONTRACT_HELPER}" list-required delegation_assignment)"
assert_contains "${delegation_required_out}" "handoff_artifacts" "delegation assignment required keys come from schema"

header "codex config helper"
CONFIG_FILE="${TMP_DIR}/config.toml"
enable_out="$(python3 "${CODEX_CONFIG_HELPER}" enable-hooks --config-file "${CONFIG_FILE}")"
assert_contains "${enable_out}" "CHANGED" "enable-hooks creates config when missing"
assert_cmd "enable-hooks writes hooks = true" grep -Eq '^hooks[[:space:]]*=[[:space:]]*true$' "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<'TOML'
[features]
hooks_beta = false
foo = true
TOML
enable_prefixed_out="$(python3 "${CODEX_CONFIG_HELPER}" enable-hooks --config-file "${CONFIG_FILE}")"
assert_contains "${enable_prefixed_out}" "CHANGED" "enable-hooks adds canonical key when only prefixed keys exist"
assert_cmd "enable-hooks preserves prefixed feature keys" grep -Eq '^hooks_beta[[:space:]]*=[[:space:]]*false$' "${CONFIG_FILE}"
assert_cmd "enable-hooks adds exact hooks key" grep -Eq '^hooks[[:space:]]*=[[:space:]]*true$' "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<'TOML'
[features] # user comment
hooks_beta = false
TOML
enable_commented_out="$(python3 "${CODEX_CONFIG_HELPER}" enable-hooks --config-file "${CONFIG_FILE}")"
assert_contains "${enable_commented_out}" "CHANGED" "enable-hooks recognizes commented features table"
assert_cmd "enable-hooks does not append duplicate commented features table" bash -c "test \$(grep -Ec '^\\[features\\]' '${CONFIG_FILE}') -eq 1"
assert_cmd "enable-hooks adds exact key under commented features table" grep -Eq '^hooks[[:space:]]*=[[:space:]]*true$' "${CONFIG_FILE}"

cat > "${CONFIG_FILE}" <<'TOML'
[features]
hooks = true
TOML
check_ok_out="$(python3 "${CODEX_CONFIG_HELPER}" check-hooks --config-file "${CONFIG_FILE}")"
assert_contains "${check_ok_out}" "OK" "check-hooks accepts valid TOML with feature enabled"

cat > "${CONFIG_FILE}" <<'TOML'
[features]
hooks = true
broken = [
TOML
check_invalid_out="$(python3 "${CODEX_CONFIG_HELPER}" check-hooks --config-file "${CONFIG_FILE}" || true)"
assert_contains "${check_invalid_out}" "INVALID" "check-hooks rejects malformed TOML"

python3 - <<'PY' "${CONFIG_FILE}"
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'[features]\nhooks = true\n\xff')
PY
check_invalid_utf8_out="$(python3 "${CODEX_CONFIG_HELPER}" check-hooks --config-file "${CONFIG_FILE}" || true)"
assert_contains "${check_invalid_utf8_out}" "INVALID" "check-hooks rejects invalid UTF-8"

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
