# GH719 managed Codex workflow skill lifecycle regressions.

header "GH719 persistent Codex skill opt-out"
gh719_home="${TMP_HOME}/gh719-home"
gh719_config="${gh719_home}/.vibeguard/config.json"
gh719_runtime="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
mkdir -p "${gh719_home}"

gh719_lock_home="${TMP_HOME}/gh719-lock-home"
mkdir -p "${gh719_lock_home}/.vibeguard/setup.lock"
printf 'pid=%s\nnonce=active-fixture\n' "$$" > "${gh719_lock_home}/.vibeguard/setup.lock/owner"
if HOME="${gh719_lock_home}" bash -c \
  'source "$1/scripts/setup/lib.sh"; setup_lock_acquire' _ "${REPO_DIR}" >/dev/null 2>&1; then
  red "active setup lifecycle lock unexpectedly succeeded"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
else
  green "active setup lifecycle lock blocks a second installer"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
fi
printf 'pid=99999999\nnonce=stale-fixture\n' > "${gh719_lock_home}/.vibeguard/setup.lock/owner"
assert_cmd "stale setup lifecycle lock is reclaimed" env HOME="${gh719_lock_home}" \
  bash -c 'source "$1/scripts/setup/lib.sh"; setup_lock_acquire; setup_lock_release' _ "${REPO_DIR}"

gh719_lock_race_home="${TMP_HOME}/gh719-lock-race-home"
gh719_lock_race_control="${TMP_HOME}/gh719-lock-race-control"
mkdir -p "${gh719_lock_race_home}/.vibeguard/setup.lock" \
  "${gh719_lock_race_control}"
printf 'pid=99999999\nnonce=stale-generation\n' \
  > "${gh719_lock_race_home}/.vibeguard/setup.lock/owner"
HOME="${gh719_lock_race_home}" bash -c '
  control_dir="$2"
  kill() {
    if builtin kill "$@" 2>/dev/null; then return 0; fi
    touch "${control_dir}/delayed_after_dead_check"
    while [[ ! -e "${control_dir}/resume_reclaim" ]]; do sleep 0.01; done
    return 1
  }
  source "$1/scripts/setup/lib.sh"
  if setup_lock_acquire; then
    touch "${control_dir}/delayed_acquired"
    setup_lock_release || true
  else
    touch "${control_dir}/delayed_rejected"
  fi
' _ "${REPO_DIR}" "${gh719_lock_race_control}" >/dev/null 2>&1 &
gh719_delayed_reclaimer_pid=$!
for _ in {1..500}; do
  [[ -e "${gh719_lock_race_control}/delayed_after_dead_check" ]] && break
  sleep 0.01
done
HOME="${gh719_lock_race_home}" bash -c '
  source "$1/scripts/setup/lib.sh"
  if setup_lock_acquire; then
    touch "$2/active_acquired"
    while [[ ! -e "$2/release_active" ]]; do sleep 0.01; done
    if setup_lock_release; then
      touch "$2/active_released"
    else
      touch "$2/active_release_failed"
    fi
  else
    touch "$2/active_rejected"
  fi
' _ "${REPO_DIR}" "${gh719_lock_race_control}" >/dev/null 2>&1 &
gh719_active_lock_pid=$!
for _ in {1..500}; do
  [[ -e "${gh719_lock_race_control}/active_acquired" ]] && break
  sleep 0.01
done
touch "${gh719_lock_race_control}/resume_reclaim"
wait "${gh719_delayed_reclaimer_pid}"
touch "${gh719_lock_race_control}/release_active"
wait "${gh719_active_lock_pid}"
assert_cmd "stale reclaimer rejects a changed owner generation" test \
  -e "${gh719_lock_race_control}/delayed_rejected"
assert_cmd "stale reclaimer never acquires over a changed owner generation" test \
  ! -e "${gh719_lock_race_control}/delayed_acquired"
assert_cmd "active owner survives a delayed stale reclaim" test \
  -e "${gh719_lock_race_control}/active_released"

gh719_clean_lock_home="${TMP_HOME}/gh719-clean-lock-home"
mkdir -p "${gh719_clean_lock_home}/.vibeguard/setup.lock"
printf 'pid=%s\nnonce=active-clean-fixture\n' "$$" \
  > "${gh719_clean_lock_home}/.vibeguard/setup.lock/owner"
printf 'must-survive\n' > "${gh719_clean_lock_home}/.vibeguard/run-hook.sh"
gh719_clean_lock_rc=0
gh719_clean_lock_out="$(
  HOME="${gh719_clean_lock_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
    bash "${REPO_DIR}/setup.sh" --clean 2>&1
)" || gh719_clean_lock_rc=$?
assert_cmd "clean is blocked by the active setup lifecycle lock" test \
  "${gh719_clean_lock_rc}" -ne 0
assert_contains "${gh719_clean_lock_out}" "another VibeGuard setup is active" \
  "clean reports the conflicting setup lifecycle owner"
assert_cmd "blocked clean preserves install assets" test \
  -e "${gh719_clean_lock_home}/.vibeguard/run-hook.sh"

gh719_state_home="${TMP_HOME}/gh719-state-home"
mkdir -p "${gh719_state_home}/.vibeguard"
printf '%s\n' '{"version":1,"files":{}}' > "${gh719_state_home}/.vibeguard/install-state.json"
printf '%s\n' "sentinel" > "${gh719_state_home}/snapshot-target"
ln -s "${gh719_state_home}/snapshot-target" \
  "${gh719_state_home}/.vibeguard/install-state.previous.json"
if HOME="${gh719_state_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" bash -c \
  'source "$1/scripts/lib/install-state.sh"; state_init core ""' _ "${REPO_DIR}" >/dev/null 2>&1; then
  red "symlinked previous install-state unexpectedly succeeded"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
else
  green "symlinked previous install-state is rejected"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
fi
assert_contains "$(cat "${gh719_state_home}/snapshot-target")" "sentinel" "snapshot target is not overwritten"

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

gh719_setup() {
  HOME="${gh719_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 \
    bash "${REPO_DIR}/setup.sh" --yes --profile core
}

gh719_setup >/dev/null 2>&1
assert_cmd "workflow skill installed by default" test -d "${gh719_home}/.codex/skills/plan-flow"

cp "${gh719_home}/.vibeguard/install-state.json" \
  "${gh719_home}/.vibeguard/install-state.valid.json"
gh719_snapshot_hash="$(shasum -a 256 "${gh719_home}/.vibeguard/installed/version" | cut -d ' ' -f1)"
gh719_wrapper_hash="$(shasum -a 256 "${gh719_home}/.vibeguard/run-hook.sh" | cut -d ' ' -f1)"
printf '%s\n' '{' > "${gh719_home}/.vibeguard/install-state.json"
if gh719_bad_state_out="$(gh719_setup 2>&1)"; then
  red "malformed install-state unexpectedly succeeded"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
else
  green "malformed install-state fails setup preflight"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
fi
assert_contains "${gh719_bad_state_out}" "refusing to mutate malformed install-state" "malformed install-state failure is visible"
assert_cmd "malformed state preserves installed snapshot" test \
  "$(shasum -a 256 "${gh719_home}/.vibeguard/installed/version" | cut -d ' ' -f1)" = \
  "${gh719_snapshot_hash}"
assert_cmd "malformed state preserves active wrapper" test \
  "$(shasum -a 256 "${gh719_home}/.vibeguard/run-hook.sh" | cut -d ' ' -f1)" = \
  "${gh719_wrapper_hash}"
mv "${gh719_home}/.vibeguard/install-state.valid.json" \
  "${gh719_home}/.vibeguard/install-state.json"

rm -rf "${gh719_home}/.codex/skills/plan-flow"
gh719_restore_out="$(gh719_setup 2>&1)"
assert_contains "${gh719_restore_out}" "RESTORING plan-flow" "reinstall reports restoring a deleted managed skill"
assert_contains "${gh719_restore_out}" "disabled_skills" "restore report names the persistent opt-out"
assert_cmd "deleted skill is restored when no opt-out is recorded" test -d "${gh719_home}/.codex/skills/plan-flow"

gh719_set_disabled plan-flow auto-optimize
gh719_disable_out="$(gh719_setup 2>&1)"
assert_contains "${gh719_disable_out}" "REMOVED plan-flow" "reinstall removes a newly disabled skill"
assert_cmd "disabled Codex skill is gone after reinstall" test ! -e "${gh719_home}/.codex/skills/plan-flow"
assert_cmd "same-name Claude skill remains installed" test -e "${gh719_home}/.claude/skills/auto-optimize"
assert_cmd "same-name Codex skill is disabled" test ! -e "${gh719_home}/.codex/skills/auto-optimize"
assert_cmd "non-disabled skills are unaffected" test -d "${gh719_home}/.codex/skills/fixflow"

gh719_repeat_out="$(gh719_setup 2>&1)"
assert_contains "${gh719_repeat_out}" "SKIP plan-flow (disabled" "repeat reinstall skips the disabled skill"
assert_not_contains "${gh719_repeat_out}" "RESTORING plan-flow" "repeat reinstall does not restore the disabled skill"
assert_cmd "disabled skill stays gone across reinstalls" test ! -e "${gh719_home}/.codex/skills/plan-flow"

gh719_check_out="$(HOME="${gh719_home}" bash "${REPO_DIR}/setup.sh" --check 2>&1)"
assert_contains "${gh719_check_out}" "[DISABLED] plan-flow" "--check reports the skill as disabled"
assert_not_contains "${gh719_check_out}" "[MISSING] plan-flow" "--check does not report a disabled skill as missing"

gh719_set_disabled
gh719_setup >/dev/null 2>&1
assert_cmd "clearing the opt-out re-enables the skill" test -d "${gh719_home}/.codex/skills/plan-flow"

gh719_set_disabled plan-flow
VIBEGUARD_DISABLED_SKILLS='' gh719_setup >/dev/null 2>&1
assert_cmd "explicit empty environment override re-enables the skill" test -d "${gh719_home}/.codex/skills/plan-flow"

printf '%s\n' '{"version":1,"disabled_skills":"plan-flow"}' > "${gh719_config}"
gh719_before_hash="$(shasum -a 256 "${gh719_home}/.vibeguard/install-state.json" | awk '{print $1}')"
if gh719_malformed_out="$(gh719_setup 2>&1)"; then
  red "malformed disabled_skills unexpectedly succeeded"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
else
  green "malformed disabled_skills fails setup"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
fi
assert_contains "${gh719_malformed_out}" "disabled_skills" "malformed disabled_skills is reported by path"
assert_contains "${gh719_malformed_out}" "config_type_error" "malformed disabled_skills fails with a typed config error"
gh719_after_hash="$(shasum -a 256 "${gh719_home}/.vibeguard/install-state.json" | awk '{print $1}')"
assert_cmd "malformed config fails before install-state mutation" test \
  "${gh719_after_hash}" = "${gh719_before_hash}"

printf '%s\n' '{"version":1,"disabled_skills":["plan-flow"]}' > "${gh719_config}"
mv "${gh719_home}/.codex/skills/plan-flow" "${gh719_home}/.codex/skills/plan-flow-managed"
mkdir -p "${gh719_home}/.codex/skills/plan-flow"
printf '%s\n' "user-owned" > "${gh719_home}/.codex/skills/plan-flow/custom.txt"
if gh719_unowned_out="$(gh719_setup 2>&1)"; then
  red "unowned disabled skill unexpectedly succeeded"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
else
  green "unowned disabled skill fails setup"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
fi
assert_cmd "unowned disabled skill is preserved" test -f "${gh719_home}/.codex/skills/plan-flow/custom.txt"
assert_not_contains "${gh719_unowned_out}" "REMOVED plan-flow" "failed ownership check does not claim removal"
