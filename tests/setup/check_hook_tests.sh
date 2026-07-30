# --- Stale hook registry detection ---
header "stale hook registry detection"
STALE_HOOK_HOME="$(mktemp -d)"
mkdir -p "${STALE_HOOK_HOME}/.claude" "${STALE_HOOK_HOME}/.codex" "${STALE_HOOK_HOME}/.vibeguard/installed/hooks"
cp "${REPO_DIR}/hooks/run-hook.sh" "${STALE_HOOK_HOME}/.vibeguard/run-hook.sh"
cp "${REPO_DIR}/hooks/run-hook-codex.sh" "${STALE_HOOK_HOME}/.vibeguard/run-hook-codex.sh"
cp -R "${REPO_DIR}/hooks/." "${STALE_HOOK_HOME}/.vibeguard/installed/hooks/"
cat > "${STALE_HOOK_HOME}/.claude/settings.json" <<JSON
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${STALE_HOOK_HOME}/.vibeguard/installed/hooks/session-tagger.sh"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${STALE_HOOK_HOME}/.codex/hooks.json" <<JSON
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${STALE_HOOK_HOME}/.vibeguard/installed/hooks/session-tagger.sh"
          }
        ]
      }
    ]
  }
}
JSON

stale_check_out="$(HOME="${STALE_HOOK_HOME}" bash "${SETUP_SCRIPT}" --check --strict 2>&1)"
stale_check_rc=$?
assert_eq "$stale_check_rc" "2" "stale hook check: strict mode exits broken"
assert_contains "$stale_check_out" "stale Claude hook command" "stale hook check: reports Claude stale command"
assert_contains "$stale_check_out" "config=~/.claude/settings.json event=Stop matcher=<none>" "stale hook check: names Claude config/event/matcher"
assert_contains "$stale_check_out" "command_path=${STALE_HOOK_HOME}/.vibeguard/installed/hooks/session-tagger.sh" "stale hook check: names missing installed hook path"
assert_contains "$stale_check_out" "stale Codex hook command" "stale hook check: reports Codex stale command"
assert_contains "$stale_check_out" "config=~/.codex/hooks.json event=Stop matcher=<none>" "stale hook check: names Codex config/event/matcher"
assert_contains "$stale_check_out" "repair=bash setup.sh --yes" "stale hook check: names repair action"

stale_verify_project_out="$(HOME="${STALE_HOOK_HOME}" bash "${SETUP_SCRIPT}" verify-project 2>&1)"
stale_verify_project_rc=$?
assert_eq "$stale_verify_project_rc" "2" "verify-project: broken required state exits 2"
assert_contains "$stale_verify_project_out" "stale Codex hook command" "verify-project: reports broken required hook state"

stale_install_check_out="$(HOME="${STALE_HOOK_HOME}" bash "${SETUP_SCRIPT}" --check --install 2>&1)"
stale_install_check_rc=$?
assert_eq "$stale_install_check_rc" "2" "install check: broken required state exits 2"
assert_contains "$stale_install_check_out" "stale Codex hook command" "install check: reports broken required hook state"

stale_verify_install_out="$(HOME="${STALE_HOOK_HOME}" bash "${SETUP_SCRIPT}" verify-install 2>&1)"
stale_verify_install_rc=$?
assert_eq "$stale_verify_install_rc" "2" "verify-install: broken required state exits 2"
assert_contains "$stale_verify_install_out" "stale Codex hook command" "verify-install: reports broken required hook state"

INVALID_PROJECT_DIR="$(mktemp -d)"
printf '{bad json\n' > "${INVALID_PROJECT_DIR}/.vibeguard.json"
install_invalid_project_out="$(cd "${INVALID_PROJECT_DIR}" && HOME="${STALE_HOOK_HOME}" bash "${SETUP_SCRIPT}" verify-install 2>&1)"
assert_contains "$install_invalid_project_out" "Project config not checked in install verification mode" "verify-install: skips project config validation"
assert_not_contains "$install_invalid_project_out" "Project config invalid" "verify-install: project config does not affect install health"

dev_repo_invalid_project_out="$(cd "${INVALID_PROJECT_DIR}" && HOME="${STALE_HOOK_HOME}" bash "${SETUP_SCRIPT}" verify-dev-repo 2>&1)"
assert_contains "$dev_repo_invalid_project_out" "Project config not checked in dev-repo verification mode" "verify-dev-repo: skips caller project config validation"
assert_not_contains "$dev_repo_invalid_project_out" "Project config invalid" "verify-dev-repo: caller project config does not affect dev repo health"

dev_repo_env_invalid_project_out="$(HOME="${STALE_HOOK_HOME}" VIBEGUARD_PROJECT_CONFIG="${INVALID_PROJECT_DIR}/.vibeguard.json" bash "${SETUP_SCRIPT}" verify-dev-repo 2>&1)"
assert_contains "$dev_repo_env_invalid_project_out" "Project config not checked in dev-repo verification mode" "verify-dev-repo: skips env project config validation"
assert_not_contains "$dev_repo_env_invalid_project_out" "Project config invalid" "verify-dev-repo: env project config does not affect dev repo health"

project_invalid_config_out="$(cd "${INVALID_PROJECT_DIR}" && HOME="${STALE_HOOK_HOME}" bash "${SETUP_SCRIPT}" verify-project 2>&1)"
assert_contains "$project_invalid_config_out" "Project config invalid" "verify-project: still validates project config"
rm -rf "${INVALID_PROJECT_DIR}"

HOME="${STALE_HOOK_HOME}" python3 "${REPO_DIR}/scripts/lib/settings_json.py" upsert-vibeguard \
  --settings-file "${STALE_HOOK_HOME}/.claude/settings.json" \
  --repo-dir "${REPO_DIR}" \
  --profile core >/dev/null
HOME="${STALE_HOOK_HOME}" python3 "${REPO_DIR}/scripts/lib/codex_hooks_json.py" upsert-vibeguard \
  --hooks-file "${STALE_HOOK_HOME}/.codex/hooks.json" \
  --wrapper "${STALE_HOOK_HOME}/.vibeguard/run-hook-codex.sh" >/dev/null
assert_cmd "stale hook repair: Claude installed hook path removed" bash -c "! grep -q '.vibeguard/installed/hooks/session-tagger.sh' '${STALE_HOOK_HOME}/.claude/settings.json'"
assert_cmd "stale hook repair: Codex installed hook path removed" bash -c "! grep -q '.vibeguard/installed/hooks/session-tagger.sh' '${STALE_HOOK_HOME}/.codex/hooks.json'"
assert_cmd "stale hook repair: Claude stale check passes" env HOME="${STALE_HOOK_HOME}" python3 "${REPO_DIR}/scripts/lib/settings_json.py" check-stale-hooks --settings-file "${STALE_HOOK_HOME}/.claude/settings.json"
assert_cmd "stale hook repair: Codex stale check passes" env HOME="${STALE_HOOK_HOME}" python3 "${REPO_DIR}/scripts/lib/codex_hooks_json.py" check-stale-hooks --hooks-file "${STALE_HOOK_HOME}/.codex/hooks.json"

# --- Codex unmanaged PreToolUse stale hook detection and explicit repair ---
header "codex unmanaged stale pretool repair"
UNMANAGED_HOOK_HOME="$(mktemp -d)"
mkdir -p "${UNMANAGED_HOOK_HOME}/.codex" "${UNMANAGED_HOOK_HOME}/.vibeguard"
printf '#!/usr/bin/env bash\n' > "${UNMANAGED_HOOK_HOME}/.vibeguard/run-hook-codex.sh"
chmod +x "${UNMANAGED_HOOK_HOME}/.vibeguard/run-hook-codex.sh"
valid_third_party="${UNMANAGED_HOOK_HOME}/valid-third-party.js"
printf 'process.exit(0)\n' > "${valid_third_party}"
cat > "${UNMANAGED_HOOK_HOME}/.codex/hooks.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node /existing/non-vibeguard.js"
          },
          {
            "type": "command",
            "command": "env FOO=1 node ${valid_third_party}"
          },
          {
            "type": "command",
            "command": "bash ${UNMANAGED_HOOK_HOME}/.vibeguard/run-hook-codex.sh vibeguard-pre-bash-guard.sh"
          }
        ]
      }
    ]
  }
}
JSON

unmanaged_helper_out="$(HOME="${UNMANAGED_HOOK_HOME}" python3 "${REPO_DIR}/scripts/lib/codex_hooks_json.py" check-stale-hooks --hooks-file "${UNMANAGED_HOOK_HOME}/.codex/hooks.json" 2>&1 || true)"
assert_contains "$unmanaged_helper_out" "repair-required unmanaged Codex blocking hook" "unmanaged stale helper: reports repair-required blocking hook"
assert_contains "$unmanaged_helper_out" "event=PreToolUse matcher=Bash command=node /existing/non-vibeguard.js" "unmanaged stale helper: names event matcher and command"
assert_contains "$unmanaged_helper_out" "command_path=/existing/non-vibeguard.js" "unmanaged stale helper: names missing command path"
assert_contains "$unmanaged_helper_out" "repair=bash setup.sh --yes --repair-stale-unmanaged-hooks" "unmanaged stale helper: names explicit repair flag"

unmanaged_strict_out="$(HOME="${UNMANAGED_HOOK_HOME}" bash "${SETUP_SCRIPT}" --check --strict 2>&1 || true)"
assert_contains "$unmanaged_strict_out" "[BROKEN] repair-required unmanaged Codex blocking hook" "setup --check --strict: promotes stale PreToolUse to broken"

HOME="${UNMANAGED_HOOK_HOME}" python3 "${REPO_DIR}/scripts/lib/codex_hooks_json.py" prune-stale-unmanaged \
  --hooks-file "${UNMANAGED_HOOK_HOME}/.codex/hooks.json" >/dev/null
assert_cmd "unmanaged stale repair removes missing PreToolUse hook" bash -c "! grep -q '/existing/non-vibeguard.js' '${UNMANAGED_HOOK_HOME}/.codex/hooks.json'"
assert_cmd "unmanaged stale repair preserves valid third-party hook" grep -q "${valid_third_party}" "${UNMANAGED_HOOK_HOME}/.codex/hooks.json"
assert_cmd "unmanaged stale repair preserves managed VibeGuard hook" grep -q "vibeguard-pre-bash-guard.sh" "${UNMANAGED_HOOK_HOME}/.codex/hooks.json"
assert_cmd "unmanaged stale repair leaves valid JSON" python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "${UNMANAGED_HOOK_HOME}/.codex/hooks.json"

# --- Project git hook detection ---
header "verify-project project git hooks"
PROJECT_HOOK_HOME="$(mktemp -d)"
PROJECT_HOOK_REPO="$(mktemp -d)"
git -C "${PROJECT_HOOK_REPO}" init -q
mkdir -p "${PROJECT_HOOK_HOME}/.vibeguard/installed/hooks/git"
printf '#!/usr/bin/env bash\n' > "${PROJECT_HOOK_HOME}/.vibeguard/pre-commit"
printf '#!/usr/bin/env bash\n' > "${PROJECT_HOOK_HOME}/.vibeguard/pre-push"
chmod +x "${PROJECT_HOOK_HOME}/.vibeguard/pre-commit" "${PROJECT_HOOK_HOME}/.vibeguard/pre-push"
printf '#!/usr/bin/env bash\n' > "${PROJECT_HOOK_HOME}/.vibeguard/installed/hooks/pre-commit-guard.sh"
printf '#!/usr/bin/env bash\n' > "${PROJECT_HOOK_HOME}/.vibeguard/installed/hooks/git/pre-push"

project_missing_out="$(cd "${PROJECT_HOOK_REPO}" && HOME="${PROJECT_HOOK_HOME}" bash "${SETUP_SCRIPT}" verify-project 2>&1)"
project_missing_rc=$?
assert_eq "$project_missing_rc" "2" "verify-project: missing project hooks exits 2"
assert_contains "$project_missing_out" "Project Git Hooks" "verify-project: includes project git hook section"
assert_contains "$project_missing_out" "[MISSING] Project pre-commit hook" "verify-project: reports missing project pre-commit hook"
assert_contains "$project_missing_out" "[MISSING] Project pre-push hook" "verify-project: reports missing project pre-push hook"

project_legacy_strict_out="$(cd "${PROJECT_HOOK_REPO}" && HOME="${PROJECT_HOOK_HOME}" bash "${SETUP_SCRIPT}" --check --strict 2>&1)"
project_legacy_strict_rc=$?
assert_eq "$project_legacy_strict_rc" "2" "--check --strict: missing project hooks exits 2"
assert_contains "$project_legacy_strict_out" "Project Git Hooks" "--check --strict: includes project git hook section"
assert_contains "$project_legacy_strict_out" "[MISSING] Project pre-commit hook" "--check --strict: reports missing project pre-commit hook"
assert_contains "$project_legacy_strict_out" "[MISSING] Project pre-push hook" "--check --strict: reports missing project pre-push hook"

project_legacy_json_out="$(cd "${PROJECT_HOOK_REPO}" && HOME="${PROJECT_HOOK_HOME}" bash "${SETUP_SCRIPT}" --check --json 2>&1)"
project_legacy_json_rc=$?
assert_eq "$project_legacy_json_rc" "2" "--check --json: missing project hooks exits 2"
assert_contains "$project_legacy_json_out" "Project pre-commit hook" "--check --json: reports missing project pre-commit hook"
assert_contains "$project_legacy_json_out" "Project pre-push hook" "--check --json: reports missing project pre-push hook"

PROJECT_NON_GIT_DIR="$(mktemp -d)"
project_non_git_out="$(cd "${PROJECT_NON_GIT_DIR}" && HOME="${PROJECT_HOOK_HOME}" bash "${SETUP_SCRIPT}" verify-project 2>&1)"
project_non_git_rc=$?
assert_eq "$project_non_git_rc" "2" "verify-project: non-git directory exits 2"
assert_contains "$project_non_git_out" "[MISSING] Project git hooks not checked (not a git repository)" "verify-project: non-git directory fails visibly"

project_non_git_strict_out="$(cd "${PROJECT_NON_GIT_DIR}" && HOME="${PROJECT_HOOK_HOME}" bash "${SETUP_SCRIPT}" --check --strict 2>&1)"
project_non_git_strict_rc=$?
assert_eq "$project_non_git_strict_rc" "2" "--check --strict: non-git directory exits 2"
assert_contains "$project_non_git_strict_out" "Project git hooks not checked" "--check --strict: non-git directory fails visibly"

project_non_git_json_out="$(cd "${PROJECT_NON_GIT_DIR}" && HOME="${PROJECT_HOOK_HOME}" bash "${SETUP_SCRIPT}" --check --json 2>&1)"
project_non_git_json_rc=$?
assert_eq "$project_non_git_json_rc" "2" "--check --json: non-git directory exits 2"
assert_contains "$project_non_git_json_out" "Project git hooks not checked" "--check --json: non-git directory fails visibly"
rm -rf "${PROJECT_NON_GIT_DIR}"

project_hook_dir="$(git -C "${PROJECT_HOOK_REPO}" rev-parse --path-format=absolute --git-path hooks)"
ln -sf "${PROJECT_HOOK_HOME}/.vibeguard/pre-commit" "${project_hook_dir}/pre-commit"
ln -sf "${PROJECT_HOOK_HOME}/.vibeguard/pre-push" "${project_hook_dir}/pre-push"
project_installed_out="$(cd "${PROJECT_HOOK_REPO}" && HOME="${PROJECT_HOOK_HOME}" bash "${SETUP_SCRIPT}" verify-project 2>&1 || true)"
assert_contains "$project_installed_out" "[OK] Project pre-commit hook installed" "verify-project: accepts installed project pre-commit hook"
assert_contains "$project_installed_out" "[OK] Project pre-push hook installed" "verify-project: accepts installed project pre-push hook"
