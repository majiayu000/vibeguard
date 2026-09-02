remove_claude_hook_for_test() {
  python3 - "${HOME}/.claude/settings.json" "$1" <<'PY'
import json
import shlex
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
script = sys.argv[2]
data = json.loads(settings_path.read_text(encoding="utf-8"))
hooks = data.get("hooks", {})
changed = False
for event, entries in list(hooks.items()):
    if not isinstance(entries, list):
        continue
    next_entries = []
    for entry in entries:
        if not isinstance(entry, dict):
            next_entries.append(entry)
            continue
        hook_entries = entry.get("hooks")
        if not isinstance(hook_entries, list):
            next_entries.append(entry)
            continue
        kept = []
        for hook in hook_entries:
            command = hook.get("command") if isinstance(hook, dict) else ""
            parts = shlex.split(command) if isinstance(command, str) else []
            if any(Path(part).name == script for part in parts):
                changed = True
                continue
            kept.append(hook)
        if kept:
            entry["hooks"] = kept
            next_entries.append(entry)
    if next_entries:
        hooks[event] = next_entries
    else:
        hooks.pop(event, None)
settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
raise SystemExit(0 if changed else 1)
PY
}

assert_profile_hook_missing_after_remove() {
  local script="$1" target="$2"
  remove_claude_hook_for_test "${script}" &&
    ! python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target "${target}"
}

assert_profile_hook_restored_after_repair() {
  local profile="$1" target="$2"
  bash "${REPO_DIR}/setup.sh" --yes --profile "${profile}" >/dev/null &&
    python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target "${target}"
}

header "setup --clean"
project_init_help_out="$(bash "${REPO_DIR}/scripts/project-init.sh" --help 2>&1)"
assert_contains "${project_init_help_out}" "Usage: project-init.sh [--no-hooks] [project_root]" "project-init help shows the command contract"
assert_contains "${project_init_help_out}" "--no-hooks" "project-init help documents read-only inspection"

printf 'user codex note\n' >> "${HOME}/.codex/AGENTS.md"
mkdir -p "${HOME}/.vibeguard/projects/session-a"
printf '{"write_mode":"warn"}\n' > "${HOME}/.vibeguard/config.json"
printf 'learn history\n' > "${HOME}/.vibeguard/projects/session-a/history.jsonl"
foreign_pre_commit="${TMP_HOME}/foreign-pre-commit"
cat > "${foreign_pre_commit}" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${foreign_pre_commit}"
rm -f "${REPO_GIT_HOOK_DIR}/pre-commit"
ln -s "${foreign_pre_commit}" "${REPO_GIT_HOOK_DIR}/pre-commit"
project_init_target="${TMP_HOME}/project-init-target"
mkdir -p "${project_init_target}"
git -C "${project_init_target}" init >/dev/null
cat > "${project_init_target}/Cargo.toml" <<'TOML'
[package]
name = "project-init-target"
version = "0.1.0"
edition = "2021"
TOML
project_init_out="$(bash "${REPO_DIR}/scripts/project-init.sh" "${project_init_target}" 2>&1)"
assert_contains "${project_init_out}" "pre-commit hook installed" "project-init installs tracked pre-commit hook"
assert_contains "${project_init_out}" "pre-push hook installed" "project-init installs tracked pre-push hook"
assert_contains "${project_init_out}" "Available static guards" "project-init distinguishes available checks from active hooks"
assert_contains "${project_init_out}" "Suggested agent guidance snippet" "project-init guidance is host-neutral"
assert_contains "${project_init_out}" "AGENTS.md or CLAUDE.md" "project-init names both supported guidance files"
assert_cmd "project-init pre-commit hook targets VibeGuard wrapper" bash -c "[[ \"\$(readlink '${project_init_target}/.git/hooks/pre-commit')\" == '${HOME}/.vibeguard/pre-commit' ]]"
assert_cmd "install-state records project-init hooks" bash -c "grep -q '${project_init_target}/.git/hooks/pre-commit' '${HOME}/.vibeguard/install-state.json'"
assert_contains "${project_init_out}" "Available checks are files in the VibeGuard checkout" "project-init does not treat checkout inventory as live protection"
assert_contains "${project_init_out}" "Git pre-commit: attached" "project-init reports attached git protection separately"
assert_contains "${project_init_out}" "cargo check" "project-init suggests the detected Rust build command"
assert_not_contains "${project_init_out}" "pytest" "project-init does not invent a Python test command for Rust projects"

setup_project_init_help="$(bash "${REPO_DIR}/setup.sh" project-init --help)"
assert_contains "${setup_project_init_help}" "Usage: project-init.sh" "setup.sh project-init forwards --help"
assert_contains "${setup_project_init_help}" "Unknown-language repositories still" "setup.sh project-init help documents unknown-language hook attachment"

project_init_read_only_target="${TMP_HOME}/project-init-read-only-target"
mkdir -p "${project_init_read_only_target}"
git -C "${project_init_read_only_target}" init >/dev/null
cat > "${project_init_read_only_target}/Cargo.toml" <<'TOML'
[package]
name = "project-init-read-only-target"
version = "0.1.0"
edition = "2021"
TOML
printf 'guidance-sentinel\n' > "${project_init_read_only_target}/AGENTS.md"
printf 'claude-sentinel\n' > "${project_init_read_only_target}/CLAUDE.md"
project_init_read_only_out="$(bash "${REPO_DIR}/setup.sh" project-init --no-hooks "${project_init_read_only_target}" 2>&1)"
project_init_read_only_target_abs="$(cd "${project_init_read_only_target}" && pwd -P)"
assert_contains "${project_init_read_only_out}" "Git hook installation skipped (--no-hooks)" "project-init read-only mode reports skipped writes"
assert_contains "${project_init_read_only_out}" "Git pre-commit: skipped (--no-hooks)" "project-init --no-hooks reports inactive git protection"
assert_contains "${project_init_read_only_out}" "(cd \"${project_init_read_only_target_abs}\" && bash \"${REPO_DIR}/setup.sh\" verify-project)" "project-init verification step targets the inspected project"
assert_cmd "project-init read-only mode does not install pre-commit" test ! -e "${project_init_read_only_target}/.git/hooks/pre-commit"
assert_cmd "project-init read-only mode does not install pre-push" test ! -e "${project_init_read_only_target}/.git/hooks/pre-push"
assert_cmd "project-init does not modify AGENTS.md" grep -qx "guidance-sentinel" "${project_init_read_only_target}/AGENTS.md"
assert_cmd "project-init does not modify CLAUDE.md" grep -qx "claude-sentinel" "${project_init_read_only_target}/CLAUDE.md"

project_init_existing_hooks_target="${TMP_HOME}/project-init-existing-hooks-target"
mkdir -p "${project_init_existing_hooks_target}/.git/hooks"
git -C "${project_init_existing_hooks_target}" init >/dev/null
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  > "${project_init_existing_hooks_target}/.git/hooks/pre-commit"
chmod +x "${project_init_existing_hooks_target}/.git/hooks/pre-commit"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  > "${project_init_existing_hooks_target}/.git/hooks/pre-push"
chmod -x "${project_init_existing_hooks_target}/.git/hooks/pre-push"
project_init_existing_hooks_out="$(
  bash "${REPO_DIR}/scripts/project-init.sh" "${project_init_existing_hooks_target}" 2>&1
)"
assert_contains "${project_init_existing_hooks_out}" \
  "Git pre-commit: unverified (existing hook is not VibeGuard-owned)" \
  "project-init does not claim foreign executable pre-commit protection"
assert_contains "${project_init_existing_hooks_out}" \
  "Git pre-push: inactive (existing hook is not executable)" \
  "project-init does not claim non-executable pre-push protection"
assert_cmd "project-init preserves foreign pre-commit hook" \
  grep -qx 'exit 0' "${project_init_existing_hooks_target}/.git/hooks/pre-commit"
assert_cmd "project-init preserves non-executable pre-push hook" \
  test ! -x "${project_init_existing_hooks_target}/.git/hooks/pre-push"

project_init_python_target="${TMP_HOME}/project-init-python-target"
mkdir -p "${project_init_python_target}"
printf '%s\n' '[project]' 'name = "project-init-python-target"' 'version = "0.1.0"' \
  > "${project_init_python_target}/pyproject.toml"
project_init_python_out="$(bash "${REPO_DIR}/scripts/project-init.sh" --no-hooks "${project_init_python_target}" 2>&1)"
assert_contains "${project_init_python_out}" "[universal] check_dependency_layers.py" "project-init lists universal Python guards"
assert_contains "${project_init_python_out}" "[python] check_duplicates.py" "project-init lists Python project guards"
assert_not_contains "${project_init_python_out}" "pytest" "project-init does not invent pytest for Python projects"

project_init_relative_target="${TMP_HOME}/project-init-relative-target"
mkdir -p "${project_init_relative_target}"
cat > "${project_init_relative_target}/Cargo.toml" <<'TOML'
[package]
name = "project-init-relative-target"
version = "0.1.0"
edition = "2021"
TOML
project_init_relative_out="$(
  cd "${REPO_DIR}" && bash scripts/project-init.sh "${project_init_relative_target}" 2>&1
)"
assert_contains "${project_init_relative_out}" "Language detected: rust" "project-init resolves a relative script path before entering the target"

project_init_node_target="${TMP_HOME}/project-init-node-target"
mkdir -p "${project_init_node_target}"
cat > "${project_init_node_target}/package.json" <<'JSON'
{
  "packageManager": "pnpm@10.0.0",
  "scripts": {
    "check": "tsc --noEmit",
    "test": "vitest run"
  },
  "devDependencies": {
    "typescript": "latest",
    "vitest": "latest"
  }
}
JSON
printf '%s\n' '{"compilerOptions":{"strict":true}}' > "${project_init_node_target}/tsconfig.json"
project_init_node_out="$(bash "${REPO_DIR}/scripts/project-init.sh" "${project_init_node_target}" 2>&1)"
assert_contains "${project_init_node_out}" '- `pnpm run check`' "project-init uses the declared package-manager check script"
assert_contains "${project_init_node_out}" '- `pnpm test`' "project-init uses the declared package-manager test script"
assert_not_contains "${project_init_node_out}" 'npx tsc --noEmit' "project-init does not invent a TypeScript build command"
assert_not_contains "${project_init_node_out}" '- `npm test`' "project-init does not replace the declared package manager"

project_init_bun_target="${TMP_HOME}/project-init-bun-target"
mkdir -p "${project_init_bun_target}"
cat > "${project_init_bun_target}/package.json" <<'JSON'
{
  "packageManager": "bun@1.2.0",
  "scripts": {
    "test": "vitest run"
  }
}
JSON
project_init_bun_out="$(bash "${REPO_DIR}/scripts/project-init.sh" "${project_init_bun_target}" 2>&1)"
assert_contains "${project_init_bun_out}" '- `bun run test`' "project-init runs Bun's declared test script"

project_init_worktree_base="${TMP_HOME}/project-init-worktree-base"
project_init_worktree_target="${TMP_HOME}/project-init-worktree-target"
mkdir -p "${project_init_worktree_base}"
git -C "${project_init_worktree_base}" init >/dev/null
cat > "${project_init_worktree_base}/Cargo.toml" <<'TOML'
[package]
name = "project-init-worktree-target"
version = "0.1.0"
edition = "2021"
TOML
git -C "${project_init_worktree_base}" add Cargo.toml
git -C "${project_init_worktree_base}" \
  -c user.name='VibeGuard Test' -c user.email='vibeguard@example.invalid' \
  commit -m 'test fixture' >/dev/null
git -C "${project_init_worktree_base}" worktree add --detach "${project_init_worktree_target}" HEAD >/dev/null
project_init_worktree_hooks="${project_init_worktree_base}/.git/hooks"
project_init_worktree_out="$(
  GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.hooksPath \
    GIT_CONFIG_VALUE_0="${project_init_worktree_hooks}" \
    bash "${REPO_DIR}/scripts/project-init.sh" "${project_init_worktree_target}" 2>&1
)"
assert_contains "${project_init_worktree_out}" "pre-commit hook installed" "project-init recognizes a linked Git worktree"
assert_cmd "project-init installs hooks through Git's resolved hook directory" \
  test -L "${project_init_worktree_hooks}/pre-commit"

project_init_unknown="${TMP_HOME}/project-init-unknown"
mkdir -p "${project_init_unknown}"
git -C "${project_init_unknown}" init >/dev/null
printf '# docs only\n' > "${project_init_unknown}/README.md"
project_init_unknown_out="$(bash "${REPO_DIR}/scripts/project-init.sh" "${project_init_unknown}" 2>&1)"
assert_contains "${project_init_unknown_out}" "No known language marker detected." "project-init reports unknown-language repositories instead of silently succeeding"
assert_not_contains "${project_init_unknown_out}" "No known language detected, skipping." "project-init no longer exits before git-hook attachment"
assert_contains "${project_init_unknown_out}" "pre-commit hook installed" "unknown-language repositories still receive pre-commit protection"
assert_contains "${project_init_unknown_out}" "pre-push hook installed" "unknown-language repositories still receive pre-push protection"
assert_contains "${project_init_unknown_out}" "[universal]" "unknown-language repositories still list universal guards"
assert_not_contains "${project_init_unknown_out}" "[python]" "unknown-language repositories do not invent language-specific guards"
assert_cmd "unknown-language project-init attaches pre-commit" bash -c "[[ \"\$(readlink '${project_init_unknown}/.git/hooks/pre-commit')\" == '${HOME}/.vibeguard/pre-commit' ]]"

upgrade_retired_skill="${HOME}/.codex/skills/plan-flow"
mkdir -p "${upgrade_retired_skill}"
printf 'managed before retirement\n' > "${upgrade_retired_skill}/SKILL.md"
python3 - "${HOME}/.vibeguard/install-state.json" "${upgrade_retired_skill}/SKILL.md" <<'PY'
import hashlib
import json
import sys

state_path, skill_file = sys.argv[1:]
with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)
state["files"][skill_file] = {
    "source": "workflows/plan-flow/SKILL.md",
    "type": "copy",
    "checksum": "sha256:" + hashlib.sha256(b"managed before retirement\n").hexdigest(),
}
with open(state_path, "w", encoding="utf-8") as handle:
    json.dump(state, handle, indent=2)
    handle.write("\n")
PY
clean_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_out}" "VibeGuard cleaned." "--clean route to cleanup process"
assert_contains "${clean_out}" "Retained install state for 1 disabled-skill quarantine" "--clean retains newly quarantined retirement ownership"
assert_cmd "--clean quarantines a newly retired managed Codex skill" test ! -e "${upgrade_retired_skill}"
assert_cmd "--clean preserves retired managed bytes in quarantine" bash -c \
  'quarantine="$(find "$1" -maxdepth 1 -type d -name ".plan-flow.vibeguard-quarantine.*" -print -quit)"; [[ -n "$quarantine" && -f "$quarantine/SKILL.md" ]]' _ \
  "${HOME}/.codex/skills"
assert_cmd "--clean preserves install state owning the new quarantine" test -f "${HOME}/.vibeguard/install-state.json"
assert_cmd "--clean removes scheduled GC entry" assert_scheduled_gc_absent
assert_cmd "--clean preserves foreign repo pre-commit hook" bash -c "[[ \"\$(readlink '${REPO_GIT_HOOK_DIR}/pre-commit')\" == '${foreign_pre_commit}' ]]"
assert_cmd "--clean removes owned repo pre-push hook" test ! -e "${REPO_GIT_HOOK_DIR}/pre-push"
assert_cmd "--clean removes tracked project-init pre-commit hook" test ! -e "${project_init_target}/.git/hooks/pre-commit"
assert_cmd "--clean removes tracked project-init pre-push hook" test ! -e "${project_init_target}/.git/hooks/pre-push"
assert_cmd "--clean removes unknown-language project-init pre-commit hook" test ! -e "${project_init_unknown}/.git/hooks/pre-commit"
assert_cmd "--clean removes linked-worktree project-init pre-commit hook" test ! -e "${project_init_worktree_hooks}/pre-commit"
assert_cmd "--clean removes ~/.vibeguard/run-hook.sh" test ! -e "${HOME}/.vibeguard/run-hook.sh"
assert_cmd "--clean removes ~/.vibeguard/run-hook-codex.sh" test ! -e "${HOME}/.vibeguard/run-hook-codex.sh"
assert_cmd "--clean removes ~/.vibeguard/pre-commit wrapper" test ! -e "${HOME}/.vibeguard/pre-commit"
assert_cmd "--clean removes ~/.vibeguard/pre-push wrapper" test ! -e "${HOME}/.vibeguard/pre-push"
assert_cmd "--clean removes installed snapshot" test ! -e "${HOME}/.vibeguard/installed"
assert_cmd "--clean preserves projects by default" test -f "${HOME}/.vibeguard/projects/session-a/history.jsonl"
assert_cmd "--clean preserves runtime config by default" test -f "${HOME}/.vibeguard/config.json"
clean_again_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_again_out}" "VibeGuard cleaned." "--clean is idempotent"
purge_out="$(bash "${REPO_DIR}/setup.sh" --clean --purge-data)"
assert_contains "${purge_out}" "VibeGuard cleaned." "--clean --purge-data succeeds"
assert_cmd "--clean --purge-data removes projects" test ! -e "${HOME}/.vibeguard/projects"
assert_cmd "--clean --purge-data removes runtime config" test ! -e "${HOME}/.vibeguard/config.json"
assert_cmd "~/.claude/skills/vibeguard has been removed after cleaning" test ! -e "${HOME}/.claude/skills/vibeguard"
assert_cmd "~/.claude/commands/vibeguard has been removed after cleaning" test ! -e "${HOME}/.claude/commands/vibeguard"
assert_cmd "~/.claude/commands/vg has been removed after cleaning" test ! -e "${HOME}/.claude/commands/vg"
assert_cmd "~/.claude/skills/agentsmd-audit has been removed after cleaning" test ! -e "${HOME}/.claude/skills/agentsmd-audit"
assert_cmd "~/.claude/skills/trajectory-review has been removed after cleaning" test ! -e "${HOME}/.claude/skills/trajectory-review"
assert_cmd "~/.codex/skills/agentsmd-audit has been removed after cleaning" test ! -e "${HOME}/.codex/skills/agentsmd-audit"
assert_cmd "~/.codex/skills/trajectory-review has been removed after cleaning" test ! -e "${HOME}/.codex/skills/trajectory-review"
assert_cmd "~/.codex/hooks.json is preserved after cleaning (for non-VibeGuard hooks)" test -f "${HOME}/.codex/hooks.json"
assert_cmd "VibeGuard managed Codex AGENTS block removed after cleaning" bash -c "! grep -q 'vibeguard-start' '${HOME}/.codex/AGENTS.md'"
assert_cmd "Unmanaged Codex AGENTS content remains after cleaning" grep -q 'user codex note' "${HOME}/.codex/AGENTS.md"
assert_cmd "VibeGuard managed Codex hooks removed after cleaning" bash -c "! grep -qE 'vibeguard-(pre-bash-guard|pre-edit-guard|pre-write-guard|post-edit-guard|post-write-guard|post-build-check|stop-guard|learn-evaluator)\\.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Pre-existing non-VibeGuard hook remains after cleaning" grep -q "node ${PREEXISTING_CODEX_HOOK_SCRIPT}" "${HOME}/.codex/hooks.json"

header "setup install default languages before rust filter"
install_default_lang_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile core)"
# GH-541: the default (core) profile delivers only the shared compact core plus
# Claude host guidance via ~/.claude/CLAUDE.md and must NOT front-inject the
# full native rule tree, so the live payload stays within the U-32 budget.
assert_contains "${install_default_lang_out}" "compact core (core profile)" "core profile install reports compact core delivery"
assert_cmd "core profile does not front-inject Python native rules" test ! -L "${HOME}/.claude/rules/vibeguard/python/quality.md"
assert_cmd "core profile does not front-inject Go native rules" test ! -L "${HOME}/.claude/rules/vibeguard/golang/quality.md"

# The full rule text stays opt-in under the full/strict profiles.
install_full_lang_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile full)"
assert_contains "${install_full_lang_out}" "manifest rules -> ~/.claude/rules/vibeguard/" "full profile install writes manifest native rules"
assert_cmd "full profile includes Python native rules" test -L "${HOME}/.claude/rules/vibeguard/python/quality.md"
assert_cmd "full profile includes Go native rules" test -L "${HOME}/.claude/rules/vibeguard/golang/quality.md"
# Switching back to core removes the previously front-injected tree.
install_core_again_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile core)"
assert_cmd "core profile removes previously injected Python native rules" test ! -L "${HOME}/.claude/rules/vibeguard/python/quality.md"
assert_cmd "core profile hooks match manifest" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target profile-hooks:core
BASH_C_PROFILE_SETTINGS="${TMP_HOME}/bash-c-profile-settings.json"
python3 - "${HOME}/.claude/settings.json" "${BASH_C_PROFILE_SETTINGS}" <<'PY'
import json
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
data = json.loads(source_path.read_text(encoding="utf-8"))
for entry in data["hooks"]["PreToolUse"]:
    if entry.get("matcher") != "Bash":
        continue
    for hook in entry.get("hooks", []):
        command = hook.get("command") if isinstance(hook, dict) else ""
        if "pre-bash-guard.sh" in command:
            hook["command"] = f"bash -c {Path.home() / '.vibeguard' / 'run-hook.sh'} pre-bash-guard.sh"
            target_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
            raise SystemExit(0)
raise SystemExit(1)
PY
assert_cmd "core profile check rejects bash -c wrapper without hook args" bash -c "! python3 '${SETTINGS_HELPER}' check --settings-file '${BASH_C_PROFILE_SETTINGS}' --target profile-hooks:core >/dev/null 2>&1"
python3 - "${HOME}/.claude/settings.json" <<'PY'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
data = json.loads(settings_path.read_text(encoding="utf-8"))
hooks = data.setdefault("hooks", {})
hooks.setdefault("PostToolUse", []).append(
    {
        "matcher": "Edit",
        "hooks": [
            {
                "type": "command",
                "command": f"node /custom/audit.js {Path.home() / '.vibeguard' / 'run-hook.sh'} post-build-check.sh",
            }
        ],
    }
)
settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
assert_cmd "core profile check allows unmanaged wrapper argument" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target profile-hooks:core
assert_cmd "core profile repair preserves unmanaged wrapper argument" bash -c "bash '${REPO_DIR}/setup.sh' --yes --profile core >/dev/null && grep -q 'node /custom/audit.js' '${HOME}/.claude/settings.json' && python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target profile-hooks:core"
python3 - "${HOME}/.claude/settings.json" <<'PY'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
data = json.loads(settings_path.read_text(encoding="utf-8"))
for entry in data["hooks"]["PreToolUse"]:
    if entry.get("matcher") != "Bash":
        continue
    for hook in entry.get("hooks", []):
        command = hook.get("command") if isinstance(hook, dict) else ""
        if "pre-bash-guard.sh" in command:
            hook["command"] = f"env VIBEGUARD_FOO=1 {Path.home() / '.vibeguard' / 'run-hook.sh'} pre-bash-guard.sh"
            settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
            raise SystemExit(0)
raise SystemExit(1)
PY
assert_cmd "core profile check allows env wrapper command" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target profile-hooks:core
assert_cmd "core profile repair preserves env wrapper command" bash -c "bash '${REPO_DIR}/setup.sh' --yes --profile core >/dev/null && grep -q 'env VIBEGUARD_FOO=1' '${HOME}/.claude/settings.json' && python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target profile-hooks:core"
assert_cmd "core profile repair does not duplicate env wrapper command" python3 -c 'import json, sys; data=json.load(open(sys.argv[1], encoding="utf-8")); commands=[hook.get("command", "") for entry in data["hooks"]["PreToolUse"] for hook in entry.get("hooks", [])]; raise SystemExit(0 if sum("pre-bash-guard.sh" in command for command in commands) == 1 else 1)' "${HOME}/.claude/settings.json"
python3 - "${HOME}/.claude/settings.json" <<'PY'
import copy
import json
import shlex
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
data = json.loads(settings_path.read_text(encoding="utf-8"))
entries = data["hooks"]["PreToolUse"]
for entry in entries:
    if entry.get("matcher") != "Bash":
        continue
    for hook in entry.get("hooks", []):
        command = hook.get("command") if isinstance(hook, dict) else ""
        parts = shlex.split(command) if isinstance(command, str) else []
        if any(Path(part).name == "pre-bash-guard.sh" for part in parts):
            entries.append(copy.deepcopy(entry))
            settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
            raise SystemExit(0)
raise SystemExit(1)
PY
assert_cmd "core profile check rejects duplicate managed hook" bash -c "! python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target profile-hooks:core >/dev/null 2>&1"
assert_cmd "core profile repair removes duplicate managed hook" assert_profile_hook_restored_after_repair core profile-hooks:core
python3 - "${HOME}/.claude/settings.json" <<'PY'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
data = json.loads(settings_path.read_text(encoding="utf-8"))
hooks = data.setdefault("hooks", {})
hooks.setdefault("SessionStart", []).append(
    {
        "hooks": [
            {
                "type": "command",
                "command": f"bash {Path.home() / '.vibeguard' / 'run-hook.sh'} skills-loader.sh",
            }
        ]
    }
)
settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
assert_cmd "core profile check allows manual skills-loader hook" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target profile-hooks:core
assert_cmd "core profile repair preserves manual skills-loader hook" bash -c "bash '${REPO_DIR}/setup.sh' --yes --profile core >/dev/null && grep -q 'skills-loader.sh' '${HOME}/.claude/settings.json' && python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target profile-hooks:core"
python3 - "${HOME}/.claude/settings.json" <<'PY'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
data = json.loads(settings_path.read_text(encoding="utf-8"))
hooks = data.setdefault("hooks", {})
entries = hooks.setdefault("PostToolUse", [])
entries.append(
    {
        "matcher": "Bash",
        "hooks": [
            {
                "type": "command",
                "command": f"bash {Path.home() / '.vibeguard' / 'run-hook.sh'} analysis-paralysis-guard.sh",
            }
        ],
    }
)
settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
assert_cmd "core profile check rejects stale same-script matcher" bash -c "! python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target profile-hooks:core >/dev/null 2>&1"
assert_cmd "core profile repair removes stale same-script matcher" assert_profile_hook_restored_after_repair core profile-hooks:core
assert_cmd "core profile check catches missing analysis-paralysis hook" assert_profile_hook_missing_after_remove analysis-paralysis-guard.sh profile-hooks:core
core_missing_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_contains "${core_missing_out}" "[MISSING] Claude hooks missing for core profile" "setup --check reports missing core profile hook"
assert_cmd "core profile repair restores analysis-paralysis hook" assert_profile_hook_restored_after_repair core profile-hooks:core
assert_cmd "setup --check reads default profile after runtime bootstrap" python3 - "${REPO_DIR}/scripts/setup/check.sh" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
bootstrap = text.index("ensure_setup_runtime_available")
profile_lookup = text.index('PROFILE="$(state_installed_profile)')
raise SystemExit(0 if bootstrap < profile_lookup else 1)
PY
old_profile_runtime="${TMP_HOME}/old-profile-runtime"
cat > "${old_profile_runtime}" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  setup-settings-check-supports-profile-hooks)
    printf '%s\n' 'Unknown command: setup-settings-check-supports-profile-hooks' >&2
    exit 2
    ;;
  setup-state-list-symlinks-under|setup-manifest-skill-links|setup-md-remove|setup-settings-check-stale|setup-codex-config-check-hooks|setup-codex-hooks-check-stale)
    exit 0
    ;;
  setup-settings-check)
    case "${4:-}" in
      profile-hooks:*) exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "${old_profile_runtime}"
old_runtime_check_out="$(VIBEGUARD_SETUP_RUNTIME="${old_profile_runtime}" bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_not_contains "${old_runtime_check_out}" "[MISSING] Claude hooks missing for core profile" "setup --check skips stale runtime profile-hook false missing"

header "setup install core --languages rust"
install_core_lang_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile core --languages rust)"
assert_contains "${install_core_lang_out}" "Languages: rust" "core --languages parameter takes effect"
assert_cmd "core --languages does not front-inject Rust native rules" test ! -e "${HOME}/.claude/rules/vibeguard/rust/quality.md"
core_lang_check_rc=0
core_lang_check_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1)" || core_lang_check_rc=$?
assert_cmd "core --languages setup --check --strict does not exit broken" test "${core_lang_check_rc}" -ne 2
assert_not_contains "${core_lang_check_out}" "CLAUDE.md declares" "core --languages check preserves Claude rule banner count"
assert_not_contains "${core_lang_check_out}" "~/.codex/AGENTS.md declares" "core --languages check preserves Codex rule banner count"
assert_cmd "core --languages CLAUDE.md rule banner matches selected rules" assert_claude_rule_banner_matches_expected_rules
assert_cmd "core --languages Codex AGENTS.md rule banner matches selected rules" assert_codex_rule_banner_matches_expected_rules

header "setup install --languages rust"
install_lang_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile full --languages rust)"
assert_contains "${install_lang_out}" "Languages: rust" "--languages parameter takes effect"
assert_cmd "--languages keeps common native rules" test -L "${HOME}/.claude/rules/vibeguard/common/security.md"
assert_cmd "--languages installs selected Rust native rules" test -L "${HOME}/.claude/rules/vibeguard/rust/quality.md"
assert_cmd "--languages removes unselected Python native rules" test ! -e "${HOME}/.claude/rules/vibeguard/python/quality.md"
assert_cmd "--languages removes unselected Go native rules" test ! -e "${HOME}/.claude/rules/vibeguard/golang/quality.md"
assert_cmd "--languages after installation --check executable" bash -c "bash '${REPO_DIR}/setup.sh' --check >/dev/null 2>&1"

header "setup --clean (after --languages)"
clean_lang_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_lang_out}" "VibeGuard cleaned." "languages profile cleaned successfully"

header "setup install --profile full"
install_full_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile full)"
assert_contains "${install_full_out}" "Profile: full" "full profile parameter takes effect"
assert_cmd "full profile configuration full hooks" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target full-hooks
assert_cmd "full profile hooks match manifest" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target profile-hooks:full
assert_cmd "full profile enable stop-guard" grep -q "stop-guard.sh" "${HOME}/.claude/settings.json"
assert_cmd "full profile enable learn-evaluator" grep -q "learn-evaluator.sh" "${HOME}/.claude/settings.json"
assert_cmd "full profile enable post-build-check" grep -q "post-build-check.sh" "${HOME}/.claude/settings.json"
assert_cmd "core profile check rejects leftover full hooks" bash -c "! python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target profile-hooks:core >/dev/null 2>&1"
full_as_core_out="$(bash "${REPO_DIR}/setup.sh" --check --strict --profile core 2>&1 || true)"
assert_contains "${full_as_core_out}" "[MISSING] Claude hooks missing for core profile" "setup --check reports core profile mismatch when full hooks remain"
assert_cmd "full profile check catches missing analysis-paralysis hook" assert_profile_hook_missing_after_remove analysis-paralysis-guard.sh profile-hooks:full
full_missing_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_contains "${full_missing_out}" "[MISSING] Claude hooks missing for full profile" "setup --check reports missing full profile hook"
assert_cmd "full profile repair restores manifest hooks" assert_profile_hook_restored_after_repair full profile-hooks:full

header "setup --clean (after full)"
clean_full_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_full_out}" "VibeGuard cleaned." "full profile cleaned successfully"
assert_cmd "full hooks have been removed after cleaning" bash -c "python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target full-hooks >/dev/null 2>&1; test \$? -ne 0"

header "setup install --profile strict"
install_strict_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile strict)"
assert_contains "${install_strict_out}" "Profile: strict" "strict profile parameter takes effect"
assert_cmd "strict profile still configures full hooks" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target full-hooks
assert_cmd "strict profile hooks match manifest" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target profile-hooks:strict
assert_cmd "strict profile enables U-32 constraint budget hook" grep -q "count_active_constraints.sh" "${HOME}/.claude/settings.json"
assert_cmd "strict profile check catches missing U-32 constraint hook" assert_profile_hook_missing_after_remove count_active_constraints.sh profile-hooks:strict
strict_missing_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_contains "${strict_missing_out}" "[MISSING] Claude hooks missing for strict profile" "setup --check reports missing strict profile hook"
assert_cmd "strict profile repair restores U-32 hook" assert_profile_hook_restored_after_repair strict profile-hooks:strict

header "setup --clean (after strict)"
clean_strict_out="$(bash "${REPO_DIR}/setup.sh" --clean)"
assert_contains "${clean_strict_out}" "VibeGuard cleaned." "strict profile cleaned successfully"
assert_cmd "strict profile clean removes U-32 constraint budget hook" bash -c "! grep -q 'count_active_constraints.sh' '${HOME}/.claude/settings.json'"
