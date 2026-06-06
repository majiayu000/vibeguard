header "setup scripts syntax"
assert_cmd "setup.sh syntax is correct" bash -n "${REPO_DIR}/setup.sh"
assert_cmd "scripts/setup/install.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/install.sh"
assert_cmd "source runtime build does not call cargo metadata" assert_prepare_runtime_from_source_no_cargo_metadata
assert_cmd "scripts/setup/check.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/check.sh"
assert_cmd "scripts/setup/clean.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/clean.sh"
assert_cmd "scripts/setup/codex-status.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/codex-status.sh"
assert_cmd "scripts/codex-contract-check.sh syntax is correct" bash -n "${REPO_DIR}/scripts/codex-contract-check.sh"
assert_cmd "scripts/install-systemd.sh syntax is correct" bash -n "${REPO_DIR}/scripts/install-systemd.sh"
assert_cmd "scripts/lib/install-state.sh syntax is correct" bash -n "${REPO_DIR}/scripts/lib/install-state.sh"
assert_cmd "scripts/lib/settings_json.py syntax is correct" python3 -m py_compile "${SETTINGS_HELPER}"
assert_cmd "scripts/lib/hooks_manifest.py syntax is correct" python3 -m py_compile "${HOOKS_MANIFEST_HELPER}"
assert_cmd "scripts/lib/project_config_validate.py syntax is correct" python3 -m py_compile "${PROJECT_CONFIG_HELPER}"
assert_cmd "scripts/lib/claude_md.py syntax is correct" python3 -m py_compile "${REPO_DIR}/scripts/lib/claude_md.py"
assert_cmd "CLAUDE.md helper counts canonical non-numeric rule ids" python3 - "${REPO_DIR}" <<'PY'
import subprocess
import sys
from pathlib import Path

repo_dir = Path(sys.argv[1])
sys.path.insert(0, str(repo_dir / "scripts/lib"))
import claude_md

canonical = subprocess.check_output(
    [
        sys.executable,
        str(repo_dir / "scripts/lib/vibeguard_manifest.py"),
        "rule-ids",
        "--source",
        "canonical",
    ],
    text=True,
).splitlines()
assert "TASTE-ANSI" in canonical
assert claude_md.count_rule_headings(repo_dir / "rules/claude-rules") == len(canonical)
PY
assert_cmd "setup shell rule counter counts canonical non-numeric rule ids" bash -c "
  set -euo pipefail
  source '${REPO_DIR}/scripts/setup/lib.sh'
  source '${REPO_DIR}/scripts/setup/targets/claude-home.sh'
  actual=\"\$(claude_rule_id_count '${REPO_DIR}/rules/claude-rules')\"
  expected=\"\$(python3 '${REPO_DIR}/scripts/lib/vibeguard_manifest.py' rule-ids --source canonical | wc -l | tr -d ' ')\"
  test \"\${actual}\" = \"\${expected}\"
"
assert_cmd "scripts/lib/codex_hooks_json.py syntax is correct" python3 -m py_compile "${CODEX_HOOKS_HELPER}"
assert_cmd "scripts/lib/codex_config_toml.py syntax is correct" python3 -m py_compile "${CODEX_CONFIG_HELPER}"
assert_cmd "hooks/_lib/codex_apply_patch_adapter.py syntax is correct" python3 -m py_compile "${REPO_DIR}/hooks/_lib/codex_apply_patch_adapter.py"
assert_cmd "vibeguard-pre-edit namespaced wrapper syntax is correct" bash -n "${REPO_DIR}/hooks/vibeguard-pre-edit-guard.sh"
assert_cmd "vibeguard-pre-write namespaced wrapper syntax is correct" bash -n "${REPO_DIR}/hooks/vibeguard-pre-write-guard.sh"
assert_cmd "vibeguard-post-edit namespaced wrapper syntax is correct" bash -n "${REPO_DIR}/hooks/vibeguard-post-edit-guard.sh"
assert_cmd "vibeguard-post-write namespaced wrapper syntax is correct" bash -n "${REPO_DIR}/hooks/vibeguard-post-write-guard.sh"
assert_cmd "scripts/setup/regenerate-hooks-from-manifest.sh syntax is correct" bash -n "${REPO_DIR}/scripts/setup/regenerate-hooks-from-manifest.sh"
assert_cmd "scripts/ci/validate-hooks-manifest.sh syntax is correct" bash -n "${REPO_DIR}/scripts/ci/validate-hooks-manifest.sh"
assert_cmd "CLAUDE.md template uses generated rule count placeholder" grep -q "__VIBEGUARD_RULE_COUNT__" "${REPO_DIR}/claude-md/vibeguard-rules.md"

header "setup help"
setup_help_rc=0
setup_help_out="$(bash "${REPO_DIR}/setup.sh" --help 2>&1)" || setup_help_rc=$?
TOTAL=$((TOTAL + 1))
if [[ "${setup_help_rc}" == "0" ]]; then
  green "setup.sh --help exits 0"
  PASS=$((PASS + 1))
else
  red "setup.sh --help exits 0 (exit code: ${setup_help_rc})"
  FAIL=$((FAIL + 1))
fi
assert_contains "${setup_help_out}" "Usage: bash setup.sh" "setup.sh --help prints usage"
assert_contains "${setup_help_out}" "--profile minimal|core|full|strict" "setup.sh --help documents profiles"
assert_not_contains "${setup_help_out}" "unknown argument" "setup.sh --help does not report unknown argument"

header "install-state argv safety"
install_state_home="${TMP_HOME}/install-state quote ' home"
install_state_repo="${TMP_HOME}/repo quote ' newline"$'\n'"dir"
install_state_dest="${install_state_home}/tracked quote ' newline"$'\n'"file.txt"
install_state_source="generated/source quote ' newline"$'\n'"file.txt"
install_state_profile="core quote ' profile"
install_state_languages="rust,py'thon"$'\n'"go"
mkdir -p "${install_state_home}/.vibeguard" "$(dirname "${install_state_dest}")" "${install_state_repo}"
printf '%s' "${install_state_repo}" > "${install_state_home}/.vibeguard/repo-path"
printf 'tracked\n' > "${install_state_dest}"
assert_cmd "install-state accepts quoted/newline values via argv" env \
  HOME="${install_state_home}" \
  SPECIAL_PROFILE="${install_state_profile}" \
  SPECIAL_LANGUAGES="${install_state_languages}" \
  SPECIAL_DEST="${install_state_dest}" \
  SPECIAL_SOURCE="${install_state_source}" \
  bash -c '
    set -euo pipefail
    source "$1"
    state_init "$SPECIAL_PROFILE" "$SPECIAL_LANGUAGES"
    state_record_file "$SPECIAL_DEST" "$SPECIAL_SOURCE" "copy"
    state_check_drift >/dev/null
    state_list >/dev/null
  ' bash "${REPO_DIR}/scripts/lib/install-state.sh"
assert_cmd "install-state preserves quoted/newline JSON values" python3 - \
  "${install_state_home}/.vibeguard/install-state.json" \
  "${install_state_profile}" \
  "${install_state_languages}" \
  "${install_state_repo}" \
  "${install_state_dest}" \
  "${install_state_source}" <<'PY'
import json
import sys

state_file, profile, languages, repo_dir, dest, source = sys.argv[1:7]
with open(state_file, encoding="utf-8") as f:
    state = json.load(f)

entry = state["files"][dest]
assert state["profile"] == profile
assert state["languages"] == languages.split(",")
assert state["repo_dir"] == repo_dir
assert entry["source"] == source
assert entry["type"] == "copy"
assert entry["checksum"].startswith("sha256:")
PY

header "manifest skill enumeration failure"
manifest_failure_stdout="${TMP_HOME}/manifest-failure.stdout"
manifest_failure_stderr="${TMP_HOME}/manifest-failure.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER=/bin/false; manifest_skill_links_checked '~/.claude/skills/'" >"${manifest_failure_stdout}" 2>"${manifest_failure_stderr}"; then
  red "manifest skill enumeration fails on helper error (expected failure)"
  FAIL=$((FAIL + 1))
else
  green "manifest skill enumeration fails on helper error"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
manifest_failure_err="$(cat "${manifest_failure_stderr}")"
assert_contains "${manifest_failure_err}" "failed to enumerate manifest skills" "manifest skill enumeration failure is visible on stderr"
assert_cmd "manifest skill enumeration failure leaves stdout empty" test ! -s "${manifest_failure_stdout}"

manifest_empty_helper="${TMP_HOME}/empty-manifest-helper.py"
cat > "${manifest_empty_helper}" <<'PY'
#!/usr/bin/env python3
raise SystemExit(0)
PY
manifest_empty_stdout="${TMP_HOME}/manifest-empty.stdout"
manifest_empty_stderr="${TMP_HOME}/manifest-empty.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER='${manifest_empty_helper}'; manifest_skill_links_checked '~/.claude/skills/'" >"${manifest_empty_stdout}" 2>"${manifest_empty_stderr}"; then
  red "manifest skill enumeration fails on empty target output (expected failure)"
  FAIL=$((FAIL + 1))
else
  green "manifest skill enumeration fails on empty target output"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
manifest_empty_err="$(cat "${manifest_empty_stderr}")"
assert_contains "${manifest_empty_err}" "no manifest skills declared for ~/.claude/skills/" "manifest skill empty target failure is visible on stderr"
assert_cmd "manifest skill empty target leaves stdout empty" test ! -s "${manifest_empty_stdout}"

manifest_whitespace_helper="${TMP_HOME}/whitespace-manifest-helper.py"
cat > "${manifest_whitespace_helper}" <<'PY'
#!/usr/bin/env python3
print("   ")
raise SystemExit(0)
PY
manifest_whitespace_stdout="${TMP_HOME}/manifest-whitespace.stdout"
manifest_whitespace_stderr="${TMP_HOME}/manifest-whitespace.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER='${manifest_whitespace_helper}'; manifest_skill_links_checked '~/.claude/skills/'" >"${manifest_whitespace_stdout}" 2>"${manifest_whitespace_stderr}"; then
  red "manifest skill enumeration fails on whitespace-only target output (expected failure)"
  FAIL=$((FAIL + 1))
else
  green "manifest skill enumeration fails on whitespace-only target output"
  PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))
manifest_whitespace_err="$(cat "${manifest_whitespace_stderr}")"
assert_contains "${manifest_whitespace_err}" "no manifest skills declared for ~/.claude/skills/" "manifest skill whitespace-only target failure is visible on stderr"

cleanup_whitespace_stdout="${TMP_HOME}/cleanup-whitespace.stdout"
cleanup_whitespace_stderr="${TMP_HOME}/cleanup-whitespace.stderr"
if bash -c "source '${REPO_DIR}/scripts/setup/lib.sh'; MANIFEST_HELPER='${manifest_whitespace_helper}'; manifest_skill_links_for_cleanup '~/.claude/skills/'" >"${cleanup_whitespace_stdout}" 2>"${cleanup_whitespace_stderr}"; then
  green "cleanup skill enumeration warns on whitespace-only target output"
  PASS=$((PASS + 1))
else
  red "cleanup skill enumeration warns on whitespace-only target output (exit code: $?)"
  FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
cleanup_whitespace_err="$(cat "${cleanup_whitespace_stderr}")"
assert_contains "${cleanup_whitespace_err}" "no manifest skills declared for ~/.claude/skills/" "cleanup whitespace-only target warning is visible on stderr"
assert_cmd "cleanup whitespace-only target leaves stdout empty" test ! -s "${cleanup_whitespace_stdout}"

header "clean continues when manifest skill enumeration fails"
broken_clean_home="${TMP_HOME}/broken-clean-home"
mkdir -p \
  "${broken_clean_home}/.claude/commands" \
  "${broken_clean_home}/.claude/agents" \
  "${broken_clean_home}/.claude/context-profiles" \
  "${broken_clean_home}/.claude/rules/vibeguard/common" \
  "${broken_clean_home}/.codex" \
  "${broken_clean_home}/.vibeguard"
ln -s "${REPO_DIR}/.claude/commands/vibeguard" "${broken_clean_home}/.claude/commands/vibeguard"
ln -s "${REPO_DIR}/.claude/commands/vg" "${broken_clean_home}/.claude/commands/vg"
touch "${broken_clean_home}/.claude/agents/dispatcher.md"
touch "${broken_clean_home}/.claude/context-profiles/dev.md"
touch "${broken_clean_home}/.claude/rules/vibeguard/common/security.md"
touch "${broken_clean_home}/.vibeguard/run-hook-codex.sh"
python3 "${SETTINGS_HELPER}" upsert-vibeguard --settings-file "${broken_clean_home}/.claude/settings.json" --repo-dir "${REPO_DIR}" --profile full >/dev/null
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${broken_clean_home}/.codex/hooks.json" --wrapper "${broken_clean_home}/.vibeguard/run-hook-codex.sh" >/dev/null
cat > "${broken_clean_home}/.codex/config.toml" <<'TOML'
[mcp_servers.vibeguard]
command = "node"
args = ["/legacy/mcp-server/dist/index.js"]
TOML
broken_clean_out="$(
  HOME="${broken_clean_home}" bash -c "
    set -euo pipefail
    source '${REPO_DIR}/scripts/setup/lib.sh'
    source '${REPO_DIR}/scripts/lib/install-state.sh'
    source '${REPO_DIR}/scripts/setup/targets/claude-home.sh'
    source '${REPO_DIR}/scripts/setup/targets/codex-home.sh'
    MANIFEST_HELPER=/bin/false
    clean_claude_home_installation
    clean_codex_home_installation
  " 2>&1
)"
assert_contains "${broken_clean_out}" "skipping skill link cleanup" "clean warns when manifest skill enumeration fails"
assert_cmd "clean continues after Claude manifest failure" test ! -e "${broken_clean_home}/.claude/commands/vibeguard"
assert_cmd "clean removes Claude vg shortcut commands after manifest failure" test ! -e "${broken_clean_home}/.claude/commands/vg"
assert_cmd "clean removes Claude agents after manifest failure" test ! -e "${broken_clean_home}/.claude/agents/dispatcher.md"
assert_cmd "clean removes Claude rules after manifest failure" test ! -e "${broken_clean_home}/.claude/rules/vibeguard"
assert_cmd "clean removes Claude hooks after manifest failure" bash -c "! grep -q 'pre-bash-guard.sh' '${broken_clean_home}/.claude/settings.json'"
assert_cmd "clean continues after Codex manifest failure" bash -c "! grep -q 'vibeguard-pre-bash-guard.sh' '${broken_clean_home}/.codex/hooks.json'"
assert_cmd "clean removes Codex wrapper after manifest failure" test ! -e "${broken_clean_home}/.vibeguard/run-hook-codex.sh"
assert_cmd "clean removes legacy Codex MCP after manifest failure" bash -c "! grep -q '^\[mcp_servers\.vibeguard\]' '${broken_clean_home}/.codex/config.toml'"

header "clean preserves unmanaged Claude command paths"
unmanaged_commands_home="${TMP_HOME}/unmanaged-commands-home"
mkdir -p \
  "${unmanaged_commands_home}/.claude/commands/vg" \
  "${unmanaged_commands_home}/.vibeguard"
printf 'custom shortcut\n' > "${unmanaged_commands_home}/.claude/commands/vg/custom.md"
unmanaged_commands_clean_out="$(
  HOME="${unmanaged_commands_home}" bash -c "
    set -euo pipefail
    source '${REPO_DIR}/scripts/setup/lib.sh'
    source '${REPO_DIR}/scripts/lib/install-state.sh'
    source '${REPO_DIR}/scripts/setup/targets/claude-home.sh'
    clean_claude_home_installation
  " 2>&1
)"
assert_contains "${unmanaged_commands_clean_out}" "Preserved unmanaged vg shortcut commands path" "clean warns before preserving unmanaged vg commands directory"
assert_cmd "clean preserves unmanaged vg commands directory" test -f "${unmanaged_commands_home}/.claude/commands/vg/custom.md"

header "retired manifest skill cleanup"
retired_home="${TMP_HOME}/retired-skill-home"
mkdir -p \
  "${retired_home}/.claude/skills" \
  "${retired_home}/.codex/skills" \
  "${retired_home}/.vibeguard"
ln -s "${REPO_DIR}/skills/vibeguard" "${retired_home}/.claude/skills/vibeguard"
ln -s "${REPO_DIR}/skills/old-retired" "${retired_home}/.claude/skills/old-retired"
ln -s "${REPO_DIR}/skills/user-skill" "${retired_home}/.claude/skills/user-skill"
mkdir -p "${retired_home}/.claude/skills/old-dir"
ln -s "${REPO_DIR}/workflows/old-flow" "${retired_home}/.codex/skills/old-flow"
python3 - <<'PY' "${retired_home}"
import json
import sys
from pathlib import Path

home = Path(sys.argv[1])
state = {
    "version": 1,
    "files": {
        str(home / ".claude/skills/vibeguard"): {"source": "skills/vibeguard", "type": "symlink"},
        str(home / ".claude/skills/old-retired"): {"source": "skills/old-retired", "type": "symlink"},
        str(home / ".claude/skills/old-dir"): {"source": "skills/old-dir", "type": "symlink"},
        str(home / ".codex/skills/old-flow"): {"source": "workflows/old-flow", "type": "symlink"},
    },
}
(home / ".vibeguard/install-state.json").write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
PY
retired_cleanup_out="$(
  HOME="${retired_home}" bash -c "
    set -euo pipefail
    source '${REPO_DIR}/scripts/setup/lib.sh'
    source '${REPO_DIR}/scripts/lib/install-state.sh'
    cleanup_retired_manifest_skill_links '~/.claude/skills/' '${retired_home}/.claude/skills'
    cleanup_retired_manifest_skill_links '~/.codex/skills/' '${retired_home}/.codex/skills'
  " 2>&1
)"
assert_contains "${retired_cleanup_out}" "Removed retired VibeGuard skill link" "retired skill cleanup reports removed managed links"
assert_cmd "retired cleanup keeps active manifest Claude skill" test -L "${retired_home}/.claude/skills/vibeguard"
assert_cmd "retired cleanup removes tracked retired Claude skill" test ! -L "${retired_home}/.claude/skills/old-retired"
assert_cmd "retired cleanup removes tracked retired Codex skill" test ! -L "${retired_home}/.codex/skills/old-flow"
assert_cmd "retired cleanup preserves untracked user skill" test -L "${retired_home}/.claude/skills/user-skill"
assert_cmd "retired cleanup preserves retired regular directories" test -d "${retired_home}/.claude/skills/old-dir"
