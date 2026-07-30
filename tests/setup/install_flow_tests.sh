# Install-flow regression suite split by concern; sourced by tests/test_setup.sh.
# shellcheck source=setup/install_core_flow_tests.sh
source "${REPO_DIR}/tests/setup/install_core_flow_tests.sh"
# shellcheck source=setup/install_scheduler_health_tests.sh
source "${REPO_DIR}/tests/setup/install_scheduler_health_tests.sh"

header "GH719 persistent skill opt-out"
gh719_home="${TMP_HOME}/gh719-home"
gh719_config="${gh719_home}/.vibeguard/config.json"
mkdir -p "${gh719_home}"

gh719_set_disabled() {
  python3 - "${gh719_config}" "$@" <<'PY'
import json, sys
path, names = sys.argv[1], sys.argv[2:]
with open(path, encoding="utf-8") as handle:
    config = json.load(handle)
config["disabled_skills"] = list(names)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
PY
}

HOME="${gh719_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes --profile core >/dev/null 2>&1
assert_cmd "workflow skill installed by default" test -d "${gh719_home}/.codex/skills/plan-flow"

# Deleting only the runtime copy is not durable: the installer restores it, but
# must report the conflict and point at the persistent opt-out.
rm -rf "${gh719_home}/.codex/skills/plan-flow"
gh719_restore_out="$(HOME="${gh719_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes --profile core 2>&1)"
assert_contains "${gh719_restore_out}" "RESTORING plan-flow" "reinstall reports restoring a deleted managed skill"
assert_contains "${gh719_restore_out}" "disabled_skills" "restore report names the persistent opt-out"
assert_cmd "deleted skill is restored when no opt-out is recorded" test -d "${gh719_home}/.codex/skills/plan-flow"

# Recording the opt-out removes the managed copy.
gh719_set_disabled plan-flow
gh719_disable_out="$(HOME="${gh719_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes --profile core 2>&1)"
assert_contains "${gh719_disable_out}" "REMOVED plan-flow" "reinstall removes a newly disabled skill"
assert_cmd "disabled skill is gone after reinstall" test ! -e "${gh719_home}/.codex/skills/plan-flow"
assert_cmd "non-disabled skills are unaffected" test -d "${gh719_home}/.codex/skills/fixflow"

# ...and it stays removed across further installs.
gh719_repeat_out="$(HOME="${gh719_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes --profile core 2>&1)"
assert_contains "${gh719_repeat_out}" "SKIP plan-flow (disabled" "repeat reinstall skips the disabled skill"
assert_not_contains "${gh719_repeat_out}" "RESTORING plan-flow" "repeat reinstall does not restore the disabled skill"
assert_cmd "disabled skill stays gone across reinstalls" test ! -e "${gh719_home}/.codex/skills/plan-flow"

gh719_check_out="$(HOME="${gh719_home}" bash "${REPO_DIR}/setup.sh" --check 2>&1)"
assert_contains "${gh719_check_out}" "[DISABLED] plan-flow" "--check reports the skill as disabled"
assert_not_contains "${gh719_check_out}" "[MISSING] plan-flow" "--check does not report a disabled skill as missing"

# Re-enabling is explicit.
gh719_set_disabled
HOME="${gh719_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes --profile core >/dev/null 2>&1
assert_cmd "clearing the opt-out re-enables the skill" test -d "${gh719_home}/.codex/skills/plan-flow"

# A malformed opt-out list fails visibly instead of reading as "nothing disabled".
printf '%s\n' '{"version":1,"disabled_skills":"plan-flow"}' > "${gh719_config}"
gh719_malformed_out="$(HOME="${gh719_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes --profile core 2>&1 || true)"
assert_contains "${gh719_malformed_out}" "disabled_skills" "malformed disabled_skills is reported by path"
assert_contains "${gh719_malformed_out}" "config_type_error" "malformed disabled_skills fails with a typed config error"
