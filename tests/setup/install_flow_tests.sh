header "hooks manifest"
assert_cmd "hooks manifest validates" bash "${REPO_DIR}/scripts/ci/validate-hooks-manifest.sh"
assert_cmd "hooks/CLAUDE.md table is generated from manifest" bash "${REPO_DIR}/scripts/setup/regenerate-hooks-from-manifest.sh" --check
assert_cmd "Codex helper specs come from hook manifest" bash -c "python3 '${HOOKS_MANIFEST_HELPER}' codex-specs | grep -q 'vibeguard-pre-bash-guard.sh'"

header "scheduled GC templates"
assert_cmd "scheduled GC script exists at canonical path" test -x "${REPO_DIR}/scripts/gc/gc-scheduled.sh"
assert_cmd "launchd plist points to canonical GC script path" grep -q "__VIBEGUARD_DIR__/scripts/gc/gc-scheduled.sh" "${REPO_DIR}/scripts/setup/com.vibeguard.gc.plist"
assert_cmd "systemd service points to canonical GC script path" grep -q "__VIBEGUARD_DIR__/scripts/gc/gc-scheduled.sh" "${REPO_DIR}/scripts/systemd/vibeguard-gc.service"
assert_cmd "systemd installer chmods canonical GC script path" grep -q 'scripts/gc/gc-scheduled.sh' "${REPO_DIR}/scripts/install-systemd.sh"
assert_cmd "scheduled GC installers do not reference legacy root path" bash -c "! grep -q 'scripts/gc-scheduled.sh' '${REPO_DIR}/scripts/setup/com.vibeguard.gc.plist' '${REPO_DIR}/scripts/systemd/vibeguard-gc.service' '${REPO_DIR}/scripts/install-systemd.sh'"

header "seed legacy config"
mkdir -p "${HOME}/.claude" "${HOME}/.codex"
cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "mcpServers": {
    "vibeguard": {
      "type": "stdio",
      "command": "node",
      "args": ["/legacy/mcp-server/dist/index.js"]
    }
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "mcp__vibeguard__guard_check",
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/post-guard-check.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/session-tagger.sh"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/cognitive-reminder.sh"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${HOME}/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node /existing/non-vibeguard.js"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/run-hook-codex.sh pre-bash-guard.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /legacy/session-tagger.sh"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${HOME}/.codex/config.toml" <<'TOML'
[mcp_servers.vibeguard]
command = "node"
args = ["/legacy/mcp-server/dist/index.js"]
TOML
assert_cmd "Legacy Claude MCP configuration has been written" grep -q "mcp-server/dist/index.js" "${HOME}/.claude/settings.json"
assert_cmd "Legacy Codex MCP configuration written" grep -q '^\[mcp_servers\.vibeguard\]' "${HOME}/.codex/config.toml"
assert_cmd "Pre-existing non-VibeGuard Codex hook is present" grep -q 'node /existing/non-vibeguard.js' "${HOME}/.codex/hooks.json"

header "setup --check"
check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${check_out}" "VibeGuard Installation Status" "--check route to status check"

bad_project_config="${TMP_HOME}/bad-vibeguard.json"
cat > "${bad_project_config}" <<'JSON'
{
  "profile": "strictest",
  "gc": {
    "log_threshold_mb": 0
  }
}
JSON
invalid_project_check_out="$(VIBEGUARD_PROJECT_CONFIG="${bad_project_config}" bash "${REPO_DIR}/setup.sh" --check 2>&1)"
assert_contains "${invalid_project_check_out}" "[FAIL] Project config invalid" "--check reports invalid .vibeguard.json"
assert_contains "${invalid_project_check_out}" ".profile: unsupported value" "--check reports invalid project profile"
assert_contains "${invalid_project_check_out}" ".gc.log_threshold_mb: expected integer >= 1" "--check reports invalid project gc threshold"
invalid_project_install_out="$(VIBEGUARD_PROJECT_CONFIG="${bad_project_config}" bash "${REPO_DIR}/setup.sh" --dry-run 2>&1 || true)"
assert_contains "${invalid_project_install_out}" "ERROR: invalid project config" "setup install refuses invalid .vibeguard.json"
assert_contains "${invalid_project_install_out}" ".profile: unsupported value" "setup install reports invalid project profile"

runtime_key_project_config="${TMP_HOME}/runtime-key-vibeguard.json"
cat > "${runtime_key_project_config}" <<'JSON'
{
  "write_mode": "block"
}
JSON
runtime_key_check_out="$(VIBEGUARD_PROJECT_CONFIG="${runtime_key_project_config}" bash "${REPO_DIR}/setup.sh" --check 2>&1)"
assert_contains "${runtime_key_check_out}" ".write_mode: unknown property" "--check keeps runtime keys invalid in .vibeguard.json"
assert_contains "${runtime_key_check_out}" "write_mode belongs in ~/.vibeguard/config.json, not .vibeguard.json" "--check points write_mode to user runtime config"

header "setup install"
dry_run_settings_sha_before="$(shasum -a 256 "${HOME}/.claude/settings.json" | cut -d' ' -f1)"
dry_run_codex_hooks_sha_before="$(shasum -a 256 "${HOME}/.codex/hooks.json" | cut -d' ' -f1)"
dry_run_codex_config_sha_before="$(shasum -a 256 "${HOME}/.codex/config.toml" | cut -d' ' -f1)"
dry_run_out="$(bash "${REPO_DIR}/setup.sh" --dry-run 2>&1)"
dry_run_settings_sha_after="$(shasum -a 256 "${HOME}/.claude/settings.json" | cut -d' ' -f1)"
dry_run_codex_hooks_sha_after="$(shasum -a 256 "${HOME}/.codex/hooks.json" | cut -d' ' -f1)"
dry_run_codex_config_sha_after="$(shasum -a 256 "${HOME}/.codex/config.toml" | cut -d' ' -f1)"
assert_contains "${dry_run_out}" "Mode: dry-run" "--dry-run reports dry-run mode"
assert_contains "${dry_run_out}" "${HOME}/.claude/settings.json" "--dry-run prints settings.json diff"
assert_contains "${dry_run_out}" "${HOME}/.claude/CLAUDE.md" "--dry-run prints CLAUDE.md diff"
assert_contains "${dry_run_out}" "${HOME}/.codex/AGENTS.md" "--dry-run prints Codex AGENTS.md diff"
assert_cmd "--dry-run does not modify ~/.claude/settings.json" test "${dry_run_settings_sha_before}" = "${dry_run_settings_sha_after}"
assert_cmd "--dry-run does not modify ~/.codex/hooks.json" test "${dry_run_codex_hooks_sha_before}" = "${dry_run_codex_hooks_sha_after}"
assert_cmd "--dry-run does not modify ~/.codex/config.toml" test "${dry_run_codex_config_sha_before}" = "${dry_run_codex_config_sha_after}"
assert_cmd "--dry-run does not create ~/.claude/CLAUDE.md" test ! -e "${HOME}/.claude/CLAUDE.md"
assert_cmd "--dry-run does not create ~/.codex/AGENTS.md" test ! -e "${HOME}/.codex/AGENTS.md"

confirm_fail_out="$(bash "${REPO_DIR}/setup.sh" 2>&1 || true)"
assert_contains "${confirm_fail_out}" "requires explicit confirmation" "non-interactive setup requires --yes for high-context writes"
assert_contains "${confirm_fail_out}" "~/.vibeguard/config.json seeded" "setup seeds runtime config file before high-context confirmation"
assert_cmd "~/.vibeguard/config.json exists after setup seed" test -f "${HOME}/.vibeguard/config.json"
assert_cmd "~/.vibeguard/config.json includes advertised runtime keys after seed" assert_runtime_config_seeded

mkdir -p "${HOME}/.claude/skills" "${HOME}/.codex/skills" "${HOME}/.vibeguard"
ln -s "${REPO_DIR}/skills/old-retired" "${HOME}/.claude/skills/old-retired"
ln -s "${REPO_DIR}/workflows/old-flow" "${HOME}/.codex/skills/old-flow"
mkdir -p "${HOME}/.codex/skills/vibeguard"
printf 'stale codex skill copy\n' > "${HOME}/.codex/skills/vibeguard/STALE.txt"
python3 - <<'PY' "${HOME}"
import json
import sys
from pathlib import Path

home = Path(sys.argv[1])
state = {
    "version": 1,
    "files": {
        str(home / ".claude/skills/old-retired"): {"source": "skills/old-retired", "type": "symlink"},
        str(home / ".codex/skills/old-flow"): {"source": "workflows/old-flow", "type": "symlink"},
    },
}
(home / ".vibeguard/install-state.json").write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
PY
CUSTOM_CARGO_TARGET_DIR="${TMP_HOME}/custom cargo target"

checksum_fail_home="${TMP_HOME}/checksum-fail-home"
mkdir -p "${checksum_fail_home}"
set +e
checksum_fail_out="$(HOME="${checksum_fail_home}" VIBEGUARD_TEST_BAD_SHA=1 VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes 2>&1)"
checksum_fail_rc=$?
set -e
assert_cmd "tampered prebuilt checksum exits nonzero" test "${checksum_fail_rc}" -ne 0
assert_contains "${checksum_fail_out}" "vibeguard-runtime checksum verification failed" "tampered prebuilt checksum reports verification failure"
assert_not_contains "${checksum_fail_out}" "Falling back to source build" "tampered prebuilt checksum does not fall back to source"
assert_not_contains "${checksum_fail_out}" "Setup complete! All components installed." "tampered prebuilt checksum does not report setup complete"

empty_version_home="${TMP_HOME}/empty-version-home"
mkdir -p "${empty_version_home}"
set +e
empty_version_out="$(HOME="${empty_version_home}" bash "${REPO_DIR}/setup.sh" --yes --runtime-version= 2>&1)"
empty_version_rc=$?
set -e
assert_cmd "empty --runtime-version exits nonzero" test "${empty_version_rc}" -ne 0
assert_contains "${empty_version_out}" "--runtime-version requires a non-empty value" "empty --runtime-version reports explicit error"
assert_not_contains "${empty_version_out}" "Setup complete! All components installed." "empty --runtime-version does not report setup complete"

version_override_home="${TMP_HOME}/version-override-home"
version_override_log="${TMP_HOME}/version-override-download.log"
mkdir -p "${version_override_home}"
: > "${version_override_log}"
version_override_out="$(HOME="${version_override_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 VIBEGUARD_TEST_DOWNLOAD_LOG="${version_override_log}" bash "${REPO_DIR}/setup.sh" --yes --runtime-version v9.9.9)"
assert_contains "${version_override_out}" "Runtime version override: v9.9.9" "--runtime-version reports selected release tag"
assert_contains "${version_override_out}" "vibeguard-runtime downloaded and verified (v9.9.9," "--runtime-version downloads selected release tag"
assert_cmd "--runtime-version passes selected tag to release download" grep -qF "tag=v9.9.9" "${version_override_log}"

curl_download_home="${TMP_HOME}/curl-download-home"
mkdir -p "${curl_download_home}"
curl_download_out="$(
  command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "gh" ]]; then
      return 1
    fi
    builtin command "$@"
  }
  export -f command
  HOME="${curl_download_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes
)"
assert_contains "${curl_download_out}" "vibeguard-runtime downloaded and verified" "prebuilt runtime downloads when gh is absent and curl is available"
assert_not_contains "${curl_download_out}" "Falling back to source build" "curl download path does not use source fallback"

source_build_home="${TMP_HOME}/source-build-home"
source_cargo_log="${TMP_HOME}/source-cargo.log"
mkdir -p "${source_build_home}"
: > "${source_cargo_log}"
source_build_out="$(HOME="${source_build_home}" CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" VIBEGUARD_TEST_CARGO_LOG="${source_cargo_log}" bash "${REPO_DIR}/setup.sh" --yes --build-from-source)"
assert_contains "${source_build_out}" "Mode: build-from-source" "--build-from-source reports source mode"
assert_contains "${source_build_out}" "Building vibeguard-runtime from source (Rust)..." "--build-from-source builds runtime from source"
assert_cmd "--build-from-source invokes cargo build" grep -qF "build --release" "${source_cargo_log}"
assert_cmd "--build-from-source uses setup-owned target dir" grep -qF -- "--target-dir" "${source_cargo_log}"
assert_cmd "--build-from-source does not install cargo target tree" test ! -d "${source_build_home}/.vibeguard/installed/cargo-target"

offline_build_home="${TMP_HOME}/offline-build-home"
offline_cargo_log="${TMP_HOME}/offline-cargo.log"
mkdir -p "${offline_build_home}"
: > "${offline_cargo_log}"
offline_build_out="$(HOME="${offline_build_home}" CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" VIBEGUARD_TEST_DOWNLOAD_FAIL=1 VIBEGUARD_TEST_CARGO_LOG="${offline_cargo_log}" bash "${REPO_DIR}/setup.sh" --yes)"
assert_contains "${offline_build_out}" "Falling back to source build" "offline prebuilt download falls back to source build"
assert_cmd "offline fallback invokes cargo build" grep -qF "build --release" "${offline_cargo_log}"
assert_cmd "offline fallback uses setup-owned target dir" grep -qF -- "--target-dir" "${offline_cargo_log}"
assert_cmd "offline fallback does not install cargo target tree" test ! -d "${offline_build_home}/.vibeguard/installed/cargo-target"

switch_runtime_home="${TMP_HOME}/switch-runtime-home"
mkdir -p "${switch_runtime_home}"
HOME="${switch_runtime_home}" CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" bash "${REPO_DIR}/setup.sh" --yes --build-from-source >/dev/null
switch_download_out="$(HOME="${switch_runtime_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes)"
assert_contains "${switch_download_out}" "vibeguard-runtime downloaded and verified" "source-built install can switch to downloaded runtime"
set +e
switch_check_out="$(HOME="${switch_runtime_home}" bash "${REPO_DIR}/setup.sh" --check --strict 2>&1)"
switch_check_rc=$?
set -e
assert_cmd "source-to-download switch remains healthy under --check --strict" test "${switch_check_rc}" -eq 0
assert_not_contains "${switch_check_out}" "[BROKEN]" "source-to-download switch does not report BROKEN"

install_out="$(VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" bash "${REPO_DIR}/setup.sh" --yes)"
assert_contains "${install_out}" "Setup complete! All components installed." "Default route to installation process"
assert_contains "${install_out}" "vibeguard-runtime downloaded and verified" "default setup uses verified prebuilt runtime without cargo"
assert_contains "${install_out}" "Scheduled GC not installed by default" "default setup reports scheduled GC opt-in"
assert_cmd "default setup does not install scheduled GC" assert_scheduled_gc_absent
assert_contains "${install_out}" "Removed retired VibeGuard skill link" "setup install removes tracked retired skill links"
assert_cmd "setup install removes tracked retired Claude skill" test ! -L "${HOME}/.claude/skills/old-retired"
assert_cmd "setup install removes tracked retired Codex skill" test ! -L "${HOME}/.codex/skills/old-flow"
assert_cmd "vg shortcut commands are installed after setup" test -L "${HOME}/.claude/commands/vg"
assert_cmd "vibeguard-runtime binary installed after setup" test -x "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
assert_cmd "runtime policy project schema installed after setup" test -f "${HOME}/.vibeguard/installed/schemas/vibeguard-project.schema.json"
assert_cmd "runtime policy project validator installed after setup" test -f "${HOME}/.vibeguard/installed/scripts/lib/project_config_validate.py"
assert_contains "${install_out}" "[OK] Installed hooks+guards snapshot matches repo HEAD" "setup install reports current installed snapshot"
assert_contains "${install_out}" "~/.vibeguard/config.json present (preserved)" "setup preserves seeded runtime config during install"
assert_cmd "pre-push wrapper is installed after setup" test -x "${HOME}/.vibeguard/pre-push"
assert_cmd "repo pre-commit hook is installed after setup" assert_repo_git_hook_target "pre-commit" "${HOME}/.vibeguard/pre-commit"
assert_cmd "repo pre-push hook is installed after setup" assert_repo_git_hook_target "pre-push" "${HOME}/.vibeguard/pre-push"
default_scheduler_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${default_scheduler_check_out}" "[INFO] Scheduled GC not installed (optional, opt in: bash setup.sh --yes --with-scheduler)" "--check reports absent scheduled GC as INFO"
assert_not_contains "${default_scheduler_check_out}" "[WARN] Scheduled GC" "--check does not warn when scheduled GC is absent"
scheduler_fail_home="${TMP_HOME}/scheduler-enable-fail-home"
mkdir -p "${scheduler_fail_home}"
set +e
scheduler_fail_out="$(HOME="${scheduler_fail_home}" CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" VIBEGUARD_TEST_UNAME=Linux VIBEGUARD_TEST_SYSTEMD_ENABLE_FAIL=1 bash "${REPO_DIR}/setup.sh" --yes --with-scheduler 2>&1)"
scheduler_fail_rc=$?
set -e
assert_cmd "--with-scheduler exits nonzero when systemd enable fails" test "${scheduler_fail_rc}" -ne 0
assert_contains "${scheduler_fail_out}" "ERROR: Scheduled GC systemd install failed" "--with-scheduler reports systemd enable failure"
assert_not_contains "${scheduler_fail_out}" "Setup complete! All components installed." "--with-scheduler failure does not report setup complete"
scheduler_install_out="$(CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" bash "${REPO_DIR}/setup.sh" --yes --with-scheduler)"
assert_contains "${scheduler_install_out}" "Mode: with-scheduler" "--with-scheduler mode is visible"
assert_contains "${scheduler_install_out}" "Scheduled GC installed via" "--with-scheduler installs scheduled GC"
assert_cmd "--with-scheduler creates scheduled GC entry" assert_scheduled_gc_present
scheduler_active_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${scheduler_active_check_out}" "[OK] Scheduled GC active" "--check reports opt-in scheduled GC active"
expected_agent_count="$(find "${REPO_DIR}/agents" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')"
printf 'user-owned agent\n' > "${HOME}/.claude/agents/user-blog-agent.md"
managed_agent_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${managed_agent_check_out}" "[OK] ${expected_agent_count} VibeGuard agents installed in ~/.claude/agents/" "--check counts only VibeGuard-managed agents"
assert_contains "${managed_agent_check_out}" "[INFO] 1 unmanaged Claude agent(s) present in ~/.claude/agents/: user-blog-agent.md" "--check reports unmanaged Claude agents separately"
rm -f "${HOME}/.claude/agents/dispatcher.md"
missing_managed_agent_check_out="$(bash "${REPO_DIR}/setup.sh" --check 2>&1 || true)"
assert_contains "${missing_managed_agent_check_out}" "[MISSING] 1/${expected_agent_count} VibeGuard agent(s) missing in ~/.claude/agents/: dispatcher.md" "--check reports missing VibeGuard-managed agents"
cp "${REPO_DIR}/agents/dispatcher.md" "${HOME}/.claude/agents/dispatcher.md"
installed_git_hook_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${installed_git_hook_check_out}" "[OK] vg shortcut commands symlinked to ~/.claude/commands/" "--check reports vg shortcut commands healthy"
assert_contains "${installed_git_hook_check_out}" "[OK] Installed hooks+guards snapshot matches repo HEAD" "--check reports installed snapshot healthy"
printf 'oldsha\n' > "${HOME}/.vibeguard/installed/version"
stale_snapshot_check_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_contains "${stale_snapshot_check_out}" "[WARN] Installed hooks+guards snapshot is stale: oldsha" "--check reports stale installed snapshot"
printf '[OK]\n' > "${HOME}/.vibeguard/installed/version"
spoof_snapshot_check_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_contains "${spoof_snapshot_check_out}" "[WARN] Installed hooks+guards snapshot is stale: [OK]" "--check treats marker-like installed snapshot as stale"
assert_contains "${spoof_snapshot_check_out}" "DEGRADED" "--check strict summary is degraded for marker-like installed snapshot"
git -C "${REPO_DIR}" rev-parse --short HEAD > "${HOME}/.vibeguard/installed/version"
wrong_claude_skill_target="${TMP_HOME}/wrong-claude-skill"
mkdir -p "${wrong_claude_skill_target}"
rm -f "${HOME}/.claude/skills/vibeguard"
ln -s "${wrong_claude_skill_target}" "${HOME}/.claude/skills/vibeguard"
drift_claude_skill_check_out="$(bash "${REPO_DIR}/setup.sh" --check 2>&1 || true)"
assert_contains "${drift_claude_skill_check_out}" "[BROKEN] vibeguard skill symlink target drift:" "--check reports Claude skill symlink target drift"
rm -f "${HOME}/.claude/skills/vibeguard"
ln -s "${REPO_DIR}/skills/vibeguard" "${HOME}/.claude/skills/vibeguard"
wrong_rule_target="${TMP_HOME}/wrong-security-rule.md"
printf '## U-17: Wrong source\n' > "${wrong_rule_target}"
rm -f "${HOME}/.claude/rules/vibeguard/common/security.md"
ln -s "${wrong_rule_target}" "${HOME}/.claude/rules/vibeguard/common/security.md"
drift_claude_rule_check_out="$(bash "${REPO_DIR}/setup.sh" --check 2>&1 || true)"
assert_contains "${drift_claude_rule_check_out}" "[BROKEN] Native rule symlink target drift:" "--check reports native rule symlink target drift"
rm -f "${HOME}/.claude/rules/vibeguard/common/security.md"
ln -s "${REPO_DIR}/rules/claude-rules/common/security.md" "${HOME}/.claude/rules/vibeguard/common/security.md"
ln -s "${REPO_DIR}/rules/claude-rules/common/workflow.md" "${HOME}/.claude/rules/vibeguard/common/stale-not-in-manifest.md"
stale_claude_rule_check_out="$(bash "${REPO_DIR}/setup.sh" --check 2>&1 || true)"
assert_contains "${stale_claude_rule_check_out}" "[BROKEN] Native rule symlink not declared by manifest:" "--check reports repo-owned native rule symlinks not declared by manifest"
rm -f "${HOME}/.claude/rules/vibeguard/common/stale-not-in-manifest.md"
rm -f "${HOME}/.claude/commands/vg"
ln -s "${REPO_DIR}/.claude/commands/missing-vg" "${HOME}/.claude/commands/vg"
broken_vg_commands_check_out="$(bash "${REPO_DIR}/setup.sh" --check 2>&1 || true)"
assert_contains "${broken_vg_commands_check_out}" "[BROKEN] vg shortcut commands symlink target missing:" "--check reports broken vg shortcut commands symlink"
rm -f "${HOME}/.claude/commands/vg"
wrong_vg_commands_target="${TMP_HOME}/wrong-vg-commands"
mkdir -p "${wrong_vg_commands_target}"
ln -s "${wrong_vg_commands_target}" "${HOME}/.claude/commands/vg"
drift_vg_commands_check_out="$(bash "${REPO_DIR}/setup.sh" --check 2>&1 || true)"
assert_contains "${drift_vg_commands_check_out}" "[BROKEN] vg shortcut commands symlink target drift:" "--check reports vg shortcut commands target drift"
rm -f "${HOME}/.claude/commands/vg"
missing_vg_commands_check_out="$(bash "${REPO_DIR}/setup.sh" --check 2>&1 || true)"
assert_contains "${missing_vg_commands_check_out}" "[MISSING] vg shortcut commands not in ~/.claude/commands/" "--check reports missing vg shortcut commands"
ln -s "${REPO_DIR}/.claude/commands/vg" "${HOME}/.claude/commands/vg"
assert_contains "${installed_git_hook_check_out}" "[OK] VibeGuard repo pre-commit hook installed" "--check reports repo pre-commit hook healthy"
assert_contains "${installed_git_hook_check_out}" "[OK] VibeGuard repo pre-push hook installed" "--check reports repo pre-push hook healthy"
fake_wrapper_repo="${TMP_HOME}/fake-wrapper-repo"
mkdir -p "${fake_wrapper_repo}/hooks/git"
printf '%s' "${fake_wrapper_repo}" > "${HOME}/.vibeguard/repo-path"
missing_wrapper_source_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${missing_wrapper_source_check_out}" "[BROKEN] VibeGuard repo pre-push hook wrapper source missing" "--check reports missing pre-push wrapper source"
printf '%s' "${REPO_DIR}" > "${HOME}/.vibeguard/repo-path"
ln -sfn "${TMP_HOME}/unexpected-pre-commit" "${REPO_GIT_HOOK_DIR}/pre-commit"
drift_git_hook_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${drift_git_hook_check_out}" "[BROKEN] VibeGuard repo pre-commit hook target drift" "--check reports repo pre-commit hook target drift"
rm -f "${REPO_GIT_HOOK_DIR}/pre-push"
missing_git_hook_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${missing_git_hook_check_out}" "[MISSING] VibeGuard repo pre-push hook" "--check reports missing repo pre-push hook"
rm -f "${HOME}/.vibeguard/pre-commit"
ln -sfn "${HOME}/.vibeguard/pre-commit" "${REPO_GIT_HOOK_DIR}/pre-commit"
broken_git_hook_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${broken_git_hook_check_out}" "[BROKEN] VibeGuard repo pre-commit hook target missing" "--check reports broken repo pre-commit hook symlink"
git_hook_repair_out="$(bash "${REPO_DIR}/setup.sh" --yes)"
assert_contains "${git_hook_repair_out}" "Setup complete! All components installed." "setup repairs missing/broken repo git hooks"
assert_cmd "repo pre-commit hook repaired by setup" assert_repo_git_hook_target "pre-commit" "${HOME}/.vibeguard/pre-commit"
assert_cmd "repo pre-push hook repaired by setup" assert_repo_git_hook_target "pre-push" "${HOME}/.vibeguard/pre-push"
outside_cwd="${TMP_HOME}/outside-cwd"
mkdir -p "${outside_cwd}"
rm -f "${REPO_GIT_HOOK_DIR}/pre-commit" "${REPO_GIT_HOOK_DIR}/pre-push"
outside_install_out="$(cd "${outside_cwd}" && bash "${REPO_DIR}/setup.sh" --yes)"
assert_contains "${outside_install_out}" "Setup complete! All components installed." "setup succeeds from outside repo cwd"
assert_cmd "outside-cwd setup installs repo pre-commit hook in real repo" assert_repo_git_hook_target "pre-commit" "${HOME}/.vibeguard/pre-commit"
assert_cmd "outside-cwd setup installs repo pre-push hook in real repo" assert_repo_git_hook_target "pre-push" "${HOME}/.vibeguard/pre-push"
assert_cmd "outside-cwd setup does not create stray hook directory" test ! -e "${outside_cwd}/.git/hooks/pre-commit"
LINKED_WORKTREE_PATH="${TMP_HOME}/linked-worktree"
git -C "${REPO_DIR}" worktree add --detach "${LINKED_WORKTREE_PATH}" HEAD >/dev/null 2>&1
# Keep this linked worktree test valid while running against uncommitted local edits.
cp "${REPO_DIR}/scripts/setup/check.sh" "${LINKED_WORKTREE_PATH}/scripts/setup/check.sh"
linked_worktree_check_out="$(cd "${LINKED_WORKTREE_PATH}" && bash setup.sh --check)"
assert_contains "${linked_worktree_check_out}" "[OK] VibeGuard repo pre-push hook installed" "--check from linked worktree accepts shared repo pre-push hook"
assert_not_contains "${linked_worktree_check_out}" "VibeGuard repo pre-push hook target drift" "--check from linked worktree does not report shared pre-push hook drift"
git -C "${REPO_DIR}" worktree remove --force "${LINKED_WORKTREE_PATH}" >/dev/null
LINKED_WORKTREE_PATH=""
assert_cmd "~/.claude/skills/vibeguard exists after installation" test -L "${HOME}/.claude/skills/vibeguard"
assert_cmd "~/.codex/skills/vibeguard is copied after installation" bash -c "test -d '${HOME}/.codex/skills/vibeguard' && test ! -L '${HOME}/.codex/skills/vibeguard'"
assert_cmd "~/.codex/skills/vibeguard stale files are removed during copy install" test ! -e "${HOME}/.codex/skills/vibeguard/STALE.txt"
assert_cmd "~/.codex/skills/vibeguard matches repository source" diff -qr "${REPO_DIR}/skills/vibeguard" "${HOME}/.codex/skills/vibeguard"
assert_cmd "~/.claude/skills/agentsmd-audit exists after installation" test -L "${HOME}/.claude/skills/agentsmd-audit"
assert_cmd "~/.claude/skills/trajectory-review exists after installation" test -L "${HOME}/.claude/skills/trajectory-review"
assert_cmd "~/.codex/skills/agentsmd-audit is copied after installation" bash -c "test -d '${HOME}/.codex/skills/agentsmd-audit' && test ! -L '${HOME}/.codex/skills/agentsmd-audit'"
assert_cmd "~/.codex/skills/trajectory-review is copied after installation" bash -c "test -d '${HOME}/.codex/skills/trajectory-review' && test ! -L '${HOME}/.codex/skills/trajectory-review'"
assert_cmd "all manifest Claude skill links are installed" assert_manifest_skill_links_installed "~/.claude/skills/" "${HOME}/.claude/skills"
assert_cmd "all manifest Codex skill links are installed" assert_manifest_skill_links_installed "~/.codex/skills/" "${HOME}/.codex/skills"
assert_cmd "Clean legacy Claude MCP block after installation" bash -c "! grep -q 'mcp-server/dist/index.js' '${HOME}/.claude/settings.json'"
assert_cmd "No longer write to mcpServers after installation" bash -c "! grep -q 'mcpServers' '${HOME}/.claude/settings.json'"
assert_cmd "settings helper detects pre hooks configured" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target pre-hooks
assert_cmd "settings helper detects post hooks configured" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target post-hooks
assert_cmd "post-guard-check is not enabled in the default installation" bash -c "! grep -q 'post-guard-check.sh' '${HOME}/.claude/settings.json'"
assert_cmd "skills-loader is not enabled in the default installation" bash -c "! grep -q 'skills-loader.sh' '${HOME}/.claude/settings.json'"
assert_cmd "The default core profile does not enable full hooks" bash -c "python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target full-hooks >/dev/null 2>&1; test \$? -ne 0"
assert_cmd "~/.codex/hooks.json exists after installation" test -f "${HOME}/.codex/hooks.json"
assert_cmd "Enable hooks feature after installation" grep -Eq '^hooks[[:space:]]*=[[:space:]]*true$' "${HOME}/.codex/config.toml"
assert_cmd "Remove deprecated codex_hooks feature after installation" bash -c "! grep -Eq '^codex_hooks[[:space:]]*=' '${HOME}/.codex/config.toml'"
assert_cmd "Clean legacy Codex MCP block after installation" bash -c "! grep -q '^\[mcp_servers\.vibeguard\]' '${HOME}/.codex/config.toml'"
assert_cmd "Codex hooks are namespaced (vibeguard prefix)" bash -c "grep -q 'vibeguard-pre-bash-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-pre-edit-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-pre-write-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-post-edit-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-post-write-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-post-build-check.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-stop-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-learn-evaluator.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Codex hooks include PermissionRequest native gates" bash -c "grep -q '\"PermissionRequest\"' '${HOME}/.codex/hooks.json' && grep -q '\"matcher\": \"Edit\"' '${HOME}/.codex/hooks.json' && grep -q '\"matcher\": \"Write\"' '${HOME}/.codex/hooks.json'"
assert_cmd "Codex helper validates managed hooks" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${HOME}/.codex/hooks.json" --wrapper "${HOME}/.vibeguard/run-hook-codex.sh"
assert_cmd "Legacy non-namespaced Codex hook command is removed" bash -c "! grep -q 'run-hook-codex.sh pre-bash-guard.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "run-hook-codex rejects non-namespaced hook names" bash -c "out=\$(printf '{\"hook_event_name\":\"PreToolUse\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | bash '${REPO_DIR}/hooks/run-hook-codex.sh' pre-bash-guard.sh); test -z \"\$out\""
assert_cmd "Codex hooks do not contain cognitive-reminder" bash -c "! grep -q 'cognitive-reminder.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Codex hooks do not contain session-tagger" bash -c "! grep -q 'session-tagger.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Pre-existing non-VibeGuard hook is preserved" grep -q 'node /existing/non-vibeguard.js' "${HOME}/.codex/hooks.json"
assert_cmd "Codex hooks include managed + preserved entries" python3 -c "import json; data=json.load(open('${HOME}/.codex/hooks.json')); total=sum(len(entries) for entries in data.get('hooks', {}).values() if isinstance(entries, list)); raise SystemExit(0 if total >= 5 else 1)"
assert_cmd "~/.claude/CLAUDE.md includes the chat contract anchor after installation" grep -qF "${CHAT_CONTRACT_ANCHOR}" "${HOME}/.claude/CLAUDE.md"
assert_cmd "~/.claude/CLAUDE.md rule banner matches installed rules" assert_claude_rule_banner_matches_installed_rules
assert_cmd "~/.codex/AGENTS.md exists after installation" test -f "${HOME}/.codex/AGENTS.md"
assert_cmd "~/.codex/AGENTS.md includes managed markers after installation" bash -c "grep -q '<!-- vibeguard-start -->' '${HOME}/.codex/AGENTS.md' && grep -q '<!-- vibeguard-end -->' '${HOME}/.codex/AGENTS.md'"
assert_cmd "~/.codex/AGENTS.md rule banner matches installed rules" assert_codex_rule_banner_matches_installed_rules
assert_cmd "~/.codex/AGENTS.md includes key Codex-visible anchors" bash -c "grep -qF 'Compact Chat Contract' '${HOME}/.codex/AGENTS.md' && grep -qF '| W-03 |' '${HOME}/.codex/AGENTS.md' && grep -qF '| SEC-13 |' '${HOME}/.codex/AGENTS.md'"
assert_cmd "templates/AGENTS.md includes the chat contract anchor" grep -qF "${CHAT_CONTRACT_ANCHOR}" "${REPO_DIR}/templates/AGENTS.md"
assert_cmd "docs/CLAUDE.md.example includes the chat contract anchor" grep -qF "${CHAT_CONTRACT_ANCHOR}" "${REPO_DIR}/docs/CLAUDE.md.example"
assert_cmd "chat contract block matches across source, installed output, and templates" assert_chat_contract_blocks_match

