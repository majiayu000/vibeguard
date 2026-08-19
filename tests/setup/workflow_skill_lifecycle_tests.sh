# GH719 managed Codex workflow skill lifecycle regressions.

header "GH719 persistent Codex skill opt-out"
gh719_home="${TMP_HOME}/gh719-home"
gh719_config="${gh719_home}/.vibeguard/config.json"
gh719_runtime="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
gh719_current_runtime_version="$(tr -d '[:space:]' < "${REPO_DIR}/vibeguard-runtime/VERSION")"
mkdir -p "${gh719_home}"

gh753_project_dir="${TMP_HOME}/gh753-project-config"
gh753_caller_dir="${TMP_HOME}/gh753-outside-caller"
mkdir -p "${gh753_project_dir}" "${gh753_caller_dir}"
printf '%s\n' '{"disabled_skills":["plan-flow"]}' \
  > "${gh753_project_dir}/.vibeguard.json"
assert_cmd "disabled skills resolve against the setup repository outside its cwd" env \
  VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
  VIBEGUARD_SETUP_RUNTIME_VERSION="${gh719_current_runtime_version}" bash -c '
    source "$1/scripts/setup/lib.sh"
    REPO_DIR="$2"
    cd "$3"
    [[ "$(disabled_skills)" == plan-flow ]]
  ' _ "${REPO_DIR}" "${gh753_project_dir}" "${gh753_caller_dir}"

assert_cmd "install cleanup releases the lock before deleting staged runtime" env \
  VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" bash -c '
    source "$1/scripts/setup/lib.sh"
    order=""
    setup_lock_release() { order="${order}release "; }
    cleanup_install_temps() { order="${order}cleanup"; }
    cleanup_install_lifecycle
    [[ "$order" == "release cleanup" ]]
  ' _ "${REPO_DIR}"
assert_cmd "install cleanup reports lock release failure after preserving order" env \
  VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" bash -c '
    source "$1/scripts/setup/lib.sh"
    order=""
    setup_lock_release() { order="${order}release "; return 1; }
    cleanup_install_temps() { order="${order}cleanup"; }
    if cleanup_install_lifecycle; then exit 1; fi
    [[ "$order" == "release cleanup" ]]
  ' _ "${REPO_DIR}"

gh719_probe_dir="${TMP_HOME}/gh719-runtime-probe"
mkdir -p "${gh719_probe_dir}"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [[ "$1" == setup-state-capabilities ]]; then echo complete-snapshot-v2; exit 0; fi' \
  'if [[ "$1" == setup-state-quarantine-count ]]; then echo "Unknown command: $1" >&2; fi' \
  'exit 1' > "${gh719_probe_dir}/partial-runtime"
chmod +x "${gh719_probe_dir}/partial-runtime"
assert_cmd "install-state resolver rejects runtimes missing a consumed command" env \
  VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" bash -c '
    source "$1/scripts/lib/install-state.sh"
    ! state_runtime_supports "$2"
  ' _ "${REPO_DIR}" "${gh719_probe_dir}/partial-runtime"

gh719_old_init_runtime="${gh719_probe_dir}/old-init-runtime"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  version) printf "%s\n" "${VIBEGUARD_TEST_RUNTIME_VERSION:?}" ;;' \
  '  setup-state-list-symlinks-under) exit 0 ;;' \
  '  setup-state-capabilities) printf "%s\n" "Unknown command: setup-state-capabilities" >&2; exit 2 ;;' \
  '  setup-state-init) printf "%s\n" "vibeguard-runtime error: Usage: vibeguard-runtime setup-state-init <state-file> <profile> <languages> [generation] [disabled-skills]" >&2; exit 1 ;;' \
  '  *) printf "%s\n" "vibeguard-runtime error: Usage: legacy fixture" >&2; exit 1 ;;' \
  'esac' > "${gh719_old_init_runtime}"
chmod +x "${gh719_old_init_runtime}"
gh719_capability_runtime="${gh719_probe_dir}/capability-runtime"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  version) printf "%s\n" "${VIBEGUARD_TEST_RUNTIME_VERSION:?}" ;;' \
  '  setup-state-list-symlinks-under) exit 0 ;;' \
  '  setup-state-capabilities)' \
  '    case "${VIBEGUARD_TEST_CAPABILITY_MODE:-valid}" in' \
  '      missing) printf "%s\n" "Unknown command: setup-state-capabilities" >&2; exit 2 ;;' \
  '      wrong) printf "%s\n" "complete-snapshot-v1" ;;' \
  '      extra) printf "%s\n" "complete-snapshot-v2" "extra" ;;' \
  '      valid) printf "%s\n" "complete-snapshot-v2" ;;' \
  '    esac' \
  '    ;;' \
  '  setup-state-init) printf "%s\n" "vibeguard-runtime error: Usage: vibeguard-runtime setup-state-init <state-file> <profile> <languages> [generation] [disabled-skills] [carry-state-file] [complete-snapshot] [codex-skills-dir]" >&2; exit 1 ;;' \
  '  *) printf "%s\n" "vibeguard-runtime error: Usage: capability fixture" >&2; exit 1 ;;' \
  'esac' > "${gh719_capability_runtime}"
chmod +x "${gh719_capability_runtime}"
gh719_capability_probe_tmp="${TMP_HOME}/gh719-capability-probe-tmp"
mkdir -p "${gh719_capability_probe_tmp}"
assert_cmd "install-state selector rejects old setup-state-init usage" env \
  VIBEGUARD_TEST_RUNTIME_VERSION="${gh719_current_runtime_version}" bash -c '
    source "$1/scripts/lib/install-state.sh"
    ! state_runtime_supports "$2"
  ' _ "${REPO_DIR}" "${gh719_old_init_runtime}"
assert_cmd "setup selector rejects old setup-state-init usage" env \
  TMPDIR="${gh719_capability_probe_tmp}" \
  VIBEGUARD_SETUP_RUNTIME_VERSION="${gh719_current_runtime_version}" \
  VIBEGUARD_TEST_RUNTIME_VERSION="${gh719_current_runtime_version}" bash -c '
    source "$1/scripts/setup/lib.sh"
    ! setup_runtime_supports "$2"
  ' _ "${REPO_DIR}" "${gh719_old_init_runtime}"
for gh719_capability_mode in missing wrong extra; do
  if [[ "${gh719_capability_mode}" == "missing" ]]; then
    gh719_capability_case="spoofed current usage without capability"
  elif [[ "${gh719_capability_mode}" == "extra" ]]; then
    gh719_capability_case="multi-line capability response"
  else
    gh719_capability_case="wrong capability token"
  fi
  assert_cmd "install-state selector rejects ${gh719_capability_case}" env \
    VIBEGUARD_TEST_CAPABILITY_MODE="${gh719_capability_mode}" \
    VIBEGUARD_TEST_RUNTIME_VERSION="${gh719_current_runtime_version}" bash -c '
      source "$1/scripts/lib/install-state.sh"
      ! state_runtime_supports "$2"
    ' _ "${REPO_DIR}" "${gh719_capability_runtime}"
  assert_cmd "setup selector rejects ${gh719_capability_case}" env \
    TMPDIR="${gh719_capability_probe_tmp}" \
    VIBEGUARD_SETUP_RUNTIME_VERSION="${gh719_current_runtime_version}" \
    VIBEGUARD_TEST_CAPABILITY_MODE="${gh719_capability_mode}" \
    VIBEGUARD_TEST_RUNTIME_VERSION="${gh719_current_runtime_version}" bash -c '
      source "$1/scripts/setup/lib.sh"
      ! setup_runtime_supports "$2"
    ' _ "${REPO_DIR}" "${gh719_capability_runtime}"
done
assert_cmd "install-state selector accepts exact capability fixture" env \
  VIBEGUARD_TEST_CAPABILITY_MODE=valid \
  VIBEGUARD_TEST_RUNTIME_VERSION="${gh719_current_runtime_version}" bash -c '
    source "$1/scripts/lib/install-state.sh"
    state_runtime_supports "$2"
  ' _ "${REPO_DIR}" "${gh719_capability_runtime}"
assert_cmd "setup selector accepts exact capability fixture" env \
  TMPDIR="${gh719_capability_probe_tmp}" \
  VIBEGUARD_SETUP_RUNTIME_VERSION="${gh719_current_runtime_version}" \
  VIBEGUARD_TEST_CAPABILITY_MODE=valid \
  VIBEGUARD_TEST_RUNTIME_VERSION="${gh719_current_runtime_version}" bash -c '
    source "$1/scripts/setup/lib.sh"
    setup_runtime_supports "$2"
  ' _ "${REPO_DIR}" "${gh719_capability_runtime}"
assert_cmd "install-state selector accepts real capability runtime" bash -c '
  source "$1/scripts/lib/install-state.sh"
  state_runtime_supports "$2"
' _ "${REPO_DIR}" "${gh719_runtime}"

gh719_cached_runtime="${gh719_probe_dir}/cached-runtime"
gh719_cached_runtime_count="${gh719_probe_dir}/cached-runtime.count"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [[ "$1" == setup-state-capabilities ]]; then' \
  '  printf "probe\n" >> "${VIBEGUARD_TEST_PROBE_COUNT:?}"' \
  '  printf "%s\n" complete-snapshot-v2' \
  '  exit 0' \
  'fi' \
  'if [[ "$1" == setup-state-generation ]]; then printf "%s\t%s\n" COMPLETE 1; exit 0; fi' \
  'printf "%s\n" "vibeguard-runtime error: Usage: fixture" >&2' \
  'exit 1' > "${gh719_cached_runtime}"
chmod +x "${gh719_cached_runtime}"
assert_cmd "install-state runtime capability probes are cached per lifecycle" env \
  VIBEGUARD_SETUP_RUNTIME="${gh719_cached_runtime}" \
  VIBEGUARD_TEST_PROBE_COUNT="${gh719_cached_runtime_count}" bash -c '
    source "$1/scripts/lib/install-state.sh"
    state_runtime setup-state-generation /unused >/dev/null
    state_runtime setup-state-generation /unused >/dev/null
    [[ "$(wc -l < "$2" | tr -d " ")" == 1 ]]
    state_runtime_cache_clear
    state_runtime setup-state-generation /unused >/dev/null
    [[ "$(wc -l < "$2" | tr -d " ")" == 2 ]]
    _INSTALL_TMP=/changed-staged-runtime
    state_runtime setup-state-generation /unused >/dev/null
    [[ "$(wc -l < "$2" | tr -d " ")" == 3 ]]
  ' _ "${REPO_DIR}" "${gh719_cached_runtime_count}"

assert_cmd "setup selector accepts real capability runtime" env \
  TMPDIR="${gh719_capability_probe_tmp}" \
  VIBEGUARD_SETUP_RUNTIME_VERSION="${gh719_current_runtime_version}" bash -c '
    source "$1/scripts/setup/lib.sh"
    setup_runtime_supports "$2"
  ' _ "${REPO_DIR}" "${gh719_runtime}"
assert_cmd "complete-snapshot capability probes create no state files" bash -c \
  '! find "$1" -mindepth 1 -print -quit | grep -q .' _ "${gh719_capability_probe_tmp}"

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
gh719_reused_pid_home="${TMP_HOME}/gh719-reused-pid-home"
mkdir -p "${gh719_reused_pid_home}/.vibeguard/setup.lock"
printf 'pid=%s\nnonce=reused-fixture|linux-v1:00000000-0000-0000-0000-000000000000:1\n' "$$" \
  > "${gh719_reused_pid_home}/.vibeguard/setup.lock/owner"
assert_cmd "reused setup-lock PID is reclaimed by process birth identity" env \
  HOME="${gh719_reused_pid_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
  bash -c 'source "$1/scripts/setup/lib.sh"; setup_lock_acquire && setup_lock_release' _ "${REPO_DIR}"
assert_cmd "zombie setup-lock owner is classified stale" env \
  HOME="${gh719_reused_pid_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
  bash -c '
    source "$1/scripts/setup/lib.sh"
    bootstrap_strong_process_snapshot() {
      BOOTSTRAP_PROCESS_STATE=Z
      BOOTSTRAP_PROCESS_IDENTITY="linux-v1:00000000-0000-0000-0000-000000000000:1"
      BOOTSTRAP_PROCESS_IDENTITY_STRENGTH=strong
    }
    [[ "$(setup_lock_owner_status "$$" "fixture|${BOOTSTRAP_PROCESS_IDENTITY:-linux-v1:00000000-0000-0000-0000-000000000000:1}")" == dead ]]
  ' _ "${REPO_DIR}"
printf 'pid=99999999\nnonce=stale-fixture\n' > "${gh719_lock_home}/.vibeguard/setup.lock/owner"
assert_cmd "stale setup lifecycle lock is reclaimed" env HOME="${gh719_lock_home}" \
  bash -c 'source "$1/scripts/setup/lib.sh"; setup_lock_acquire; setup_lock_release' _ "${REPO_DIR}"

gh719_reclaim_lock_home="${TMP_HOME}/gh719-reclaim-lock-home"
mkdir -p "${gh719_reclaim_lock_home}/.vibeguard/setup.lock"
printf 'pid=99999999\nnonce=stale-owner\n' \
  > "${gh719_reclaim_lock_home}/.vibeguard/setup.lock/owner"
printf 'pid=99999998\nnonce=stale-reclaimer\n' \
  > "${gh719_reclaim_lock_home}/.vibeguard/setup.lock/reclaiming"
assert_cmd "crashed stale setup-lock reclaimer is recovered" env \
  HOME="${gh719_reclaim_lock_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
  bash -c 'source "$1/scripts/setup/lib.sh"; setup_lock_acquire; setup_lock_release' _ "${REPO_DIR}"

gh719_lock_publish_home="${TMP_HOME}/gh719-lock-publish-home"
if HOME="${gh719_lock_publish_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
  VIBEGUARD_TEST_SETUP_LOCK_ACQUIRE_BEFORE_RENAME=1 bash -c '
  source "$1/scripts/setup/lib.sh"
  setup_lock_acquire
' _ "${REPO_DIR}" >/dev/null 2>&1; then
  red "interrupted setup lock publication unexpectedly succeeded"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
else
  green "interrupted setup lock publication fails visibly"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
fi
assert_cmd "publication interruption leaves no ownerless canonical lock" test \
  ! -e "${gh719_lock_publish_home}/.vibeguard/setup.lock"

gh719_lock_release_crash_home="${TMP_HOME}/gh719-lock-release-crash-home"
gh719_lock_release_crash_rc=0
HOME="${gh719_lock_release_crash_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
  VIBEGUARD_TEST_SETUP_LOCK_RELEASE_AFTER_RENAME=1 bash -c '
    source "$1/scripts/setup/lib.sh"
    setup_lock_acquire
    setup_lock_release
  ' _ "${REPO_DIR}" >/dev/null 2>&1 || gh719_lock_release_crash_rc=$?
assert_cmd "injected setup-lock release interruption is visible" test \
  "${gh719_lock_release_crash_rc}" -ne 0
assert_cmd "release interruption leaves no ownerless canonical lock" test \
  ! -e "${gh719_lock_release_crash_home}/.vibeguard/setup.lock"
assert_cmd "setup lock is reacquirable after interrupted release" env \
  HOME="${gh719_lock_release_crash_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
  bash -c 'source "$1/scripts/setup/lib.sh"; setup_lock_acquire && setup_lock_release' _ "${REPO_DIR}"

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

gh719_remove_race_home="${TMP_HOME}/gh719-remove-race-home"
gh719_remove_race_skill="${gh719_remove_race_home}/.codex/skills/plan-flow"
mkdir -p "${gh719_remove_race_skill}" "${gh719_remove_race_home}/.vibeguard"
printf 'managed\n' > "${gh719_remove_race_skill}/SKILL.md"
python3 - "${gh719_remove_race_home}/.vibeguard/install-state.json" \
  "${gh719_remove_race_skill}/SKILL.md" <<'PY'
import json, sys
state, skill_file = sys.argv[1:]
with open(state, "w", encoding="utf-8") as handle:
    json.dump({"version": 1, "files": {skill_file: {
        "source": "skills/plan-flow/SKILL.md", "type": "copy",
        "checksum": "sha256:5b4bc29f140e30c01417d810e700ecc54a84a0107566d84215b42e5742ef8d96"
    }}}, handle)
PY
gh719_remove_race_rc=0
HOME="${gh719_remove_race_home}" \
  VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
  VIBEGUARD_TEST_REMOVE_PUBLIC_REPLACEMENT='user-owned after verify' bash -c '
  source "$1/scripts/setup/lib.sh"
  source "$1/scripts/lib/install-state.sh"
  dest="$2"
  remove_disabled_skill \
    "${dest}" plan-flow "$(dirname "${dest}")" skills/plan-flow
' _ "${REPO_DIR}" "${gh719_remove_race_skill}" >/dev/null 2>&1 \
  || gh719_remove_race_rc=$?
assert_cmd "concurrent skill replacement fails disabled removal" test \
  "${gh719_remove_race_rc}" -ne 0
assert_cmd "concurrent user skill replacement is preserved" test \
  -f "${gh719_remove_race_skill}/custom.txt"
gh719_remove_race_quarantine="$(find "$(dirname "${gh719_remove_race_skill}")" \
  -maxdepth 1 -type d -name '.plan-flow.vibeguard-quarantine.*' -print -quit)"
assert_cmd "concurrent replacement retains the managed quarantine" test \
  -f "${gh719_remove_race_quarantine}/SKILL.md"

gh719_quarantine_collision_home="${TMP_HOME}/gh719-quarantine-collision-home"
gh719_quarantine_collision_skill="${gh719_quarantine_collision_home}/.codex/skills/plan-flow"
mkdir -p "${gh719_quarantine_collision_skill}" "${gh719_quarantine_collision_home}/.vibeguard"
printf 'managed\n' > "${gh719_quarantine_collision_skill}/SKILL.md"
python3 - "${gh719_quarantine_collision_home}/.vibeguard/install-state.json" \
  "${gh719_quarantine_collision_skill}/SKILL.md" <<'PY'
import json, sys
state, skill_file = sys.argv[1:]
with open(state, "w", encoding="utf-8") as handle:
    json.dump({"version": 1, "files": {skill_file: {
        "source": "skills/plan-flow/SKILL.md", "type": "copy",
        "checksum": "sha256:5b4bc29f140e30c01417d810e700ecc54a84a0107566d84215b42e5742ef8d96"
    }}}, handle)
PY
gh719_quarantine_collision_hash="$(
  shasum -a 256 "${gh719_quarantine_collision_skill}/SKILL.md" | awk '{print $1}'
)"
gh719_quarantine_collision_rc=0
gh719_quarantine_collision_out="$(
  HOME="${gh719_quarantine_collision_home}" \
    VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
    VIBEGUARD_TEST_REMOVE_COLLIDE_ALL=1 bash -c '
    source "$1/scripts/setup/lib.sh"
    source "$1/scripts/lib/install-state.sh"
    dest="$2"
    remove_disabled_skill \
      "${dest}" plan-flow "$(dirname "${dest}")" skills/plan-flow
  ' _ "${REPO_DIR}" "${gh719_quarantine_collision_skill}" 2>&1
)" || gh719_quarantine_collision_rc=$?
assert_cmd "quarantine destination collisions fail disabled removal" test \
  "${gh719_quarantine_collision_rc}" -ne 0
assert_contains "${gh719_quarantine_collision_out}" \
  "failed to reserve unique quarantine" \
  "quarantine destination collision failure is visible"
assert_cmd "quarantine collision preserves the public skill file" test \
  -f "${gh719_quarantine_collision_skill}/SKILL.md"
assert_cmd "quarantine collision preserves exact public skill bytes" test \
  "$(shasum -a 256 "${gh719_quarantine_collision_skill}/SKILL.md" | awk '{print $1}')" = \
  "${gh719_quarantine_collision_hash}"
assert_cmd "quarantine collision does not nest the managed tree" test \
  ! -e "${gh719_quarantine_collision_skill}/plan-flow"
assert_cmd "quarantine collision data never enters the public tree" test \
  ! -e "${gh719_quarantine_collision_skill}/collision-sentinel"

gh719_postverify_home="${TMP_HOME}/gh719-postverify-home"
gh719_postverify_skill="${gh719_postverify_home}/.codex/skills/plan-flow"
mkdir -p "${gh719_postverify_skill}" "${gh719_postverify_home}/.vibeguard"
printf 'managed\n' > "${gh719_postverify_skill}/SKILL.md"
cp "${gh719_quarantine_collision_home}/.vibeguard/install-state.json" \
  "${gh719_postverify_home}/.vibeguard/install-state.json"
python3 - "${gh719_postverify_home}/.vibeguard/install-state.json" \
  "${gh719_quarantine_collision_skill}" "${gh719_postverify_skill}" <<'PY'
import json, sys
state, old_root, new_root = sys.argv[1:]
with open(state, encoding="utf-8") as handle:
    data = json.load(handle)
data["files"] = {path.replace(old_root, new_root, 1): value for path, value in data["files"].items()}
with open(state, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
gh719_postverify_rc=0
gh719_postverify_out="$(
  HOME="${gh719_postverify_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
    VIBEGUARD_TEST_REMOVE_POSTVERIFY_INJECT=POSTVERIFY_DELETED bash -c '
      source "$1/scripts/setup/lib.sh"
      source "$1/scripts/lib/install-state.sh"
      dest="$2"
      remove_disabled_skill \
        "${dest}" plan-flow "$(dirname "${dest}")" skills/plan-flow
    ' _ "${REPO_DIR}" "${gh719_postverify_skill}" 2>&1
)" || gh719_postverify_rc=$?
assert_cmd "post-verification injection fails disabled removal" test \
  "${gh719_postverify_rc}" -ne 0
assert_contains "${gh719_postverify_out}" "changed after ownership verification" \
  "post-verification injection reports fail-closed mutation"
assert_cmd "post-verification injection preserves managed public bytes" test \
  ! -e "${gh719_postverify_skill}"
gh719_postverify_quarantine="$(find "$(dirname "${gh719_postverify_skill}")" -maxdepth 1 \
  -type d -name '.plan-flow.vibeguard-quarantine.*' -print -quit)"
assert_cmd "post-verification mutation retains managed quarantine" test \
  -f "${gh719_postverify_quarantine}/SKILL.md"
assert_contains "$(cat "${gh719_postverify_quarantine}/POSTVERIFY_DELETED")" "user-data" \
  "post-verification user data is never deleted"

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

gh719_retry_state_home="${TMP_HOME}/gh719-retry-state-home"
mkdir -p "${gh719_retry_state_home}/.vibeguard"
printf '%s\n' '{"version":1,"generation":4,"complete":true,"files":{"/managed/SKILL.md":{"source":"skills/plan-flow/SKILL.md","type":"copy","checksum":"sha256:5b4bc29f140e30c01417d810e700ecc54a84a0107566d84215b42e5742ef8d96"}}}' \
  > "${gh719_retry_state_home}/.vibeguard/install-state.previous.json"
gh719_retry_dest="${gh719_retry_state_home}/.codex/skills/plan-flow"
gh719_retry_quarantine="${gh719_retry_state_home}/.codex/skills/.plan-flow.vibeguard-quarantine.retry"
gh719_retry_transaction="${gh719_retry_state_home}/.codex/skills/.plan-flow.vibeguard-transaction.retry.json"
python3 - "${gh719_retry_state_home}/.vibeguard/install-state.json" \
  "${gh719_retry_dest}" "${gh719_retry_quarantine}" "${gh719_retry_transaction}" <<'PY'
import hashlib, json, sys
path, dest, quarantine, transaction = sys.argv[1:]
entry = {"source": "skills/plan-flow/SKILL.md", "type": "copy",
         "checksum": "sha256:5b4bc29f140e30c01417d810e700ecc54a84a0107566d84215b42e5742ef8d96"}
files = {dest + "/SKILL.md": entry}
canonical = json.dumps(files, sort_keys=True, separators=(",", ":"))
digest = "sha256:" + hashlib.sha256(canonical.encode()).hexdigest()
record = {"version": 1, "quarantine": quarantine, "transaction": transaction,
          "source_prefix": "skills/plan-flow", "tracked_digest": digest,
          "install_state_generation": 5, "nonce": "retry"}
state = {"version": 1, "generation": 5, "complete": False,
         "files": files,
         "disabled_skill_quarantines": {dest: record}}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
PY
# Preflight proves the durable artifacts an active record names, so the
# fixture must materialize the quarantine directory and its transaction.
mkdir -p "${gh719_retry_quarantine}" && printf 'managed\n' > "${gh719_retry_quarantine}/SKILL.md"
python3 - "${gh719_retry_transaction}" "${gh719_retry_dest}" \
  "${gh719_retry_quarantine}" "${gh719_retry_state_home}/.vibeguard/install-state.json" <<'PY'
import json, sys
path, dest, quarantine, state_path = sys.argv[1:]
state = json.load(open(state_path, encoding="utf-8"))
digest = state["disabled_skill_quarantines"][dest]["tracked_digest"]
transaction = {"version": 1, "phase": "committed", "dest": dest,
               "quarantine": quarantine, "transaction": path,
               "source_prefix": "skills/plan-flow",
               "tracked_digest": digest,
               "install_state_generation": 5, "nonce": "retry"}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(transaction, handle)
PY
gh719_last_complete_hash="$(shasum -a 256 "${gh719_retry_state_home}/.vibeguard/install-state.previous.json" | awk '{print $1}')"
HOME="${gh719_retry_state_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" bash -c \
  'source "$1/scripts/lib/install-state.sh"; state_init core ""' _ "${REPO_DIR}"
assert_cmd "retry preserves the last complete ownership generation" test \
  "$(shasum -a 256 "${gh719_retry_state_home}/.vibeguard/install-state.previous.json" | awk '{print $1}')" = \
  "${gh719_last_complete_hash}"
assert_cmd "retry reuses the interrupted next generation" python3 -c \
  'import json,sys; d=json.load(open(sys.argv[1])); dest=sys.argv[2]; assert d["generation"] == 5 and d["complete"] is False; assert dest in d["disabled_skill_quarantines"] and dest + "/SKILL.md" in d["files"]' \
  "${gh719_retry_state_home}/.vibeguard/install-state.json" "${gh719_retry_dest}"

gh719_previous_only_home="${TMP_HOME}/gh719-previous-only-home"
gh719_previous_only_dest="${gh719_previous_only_home}/.codex/skills/retired"
gh719_previous_only_quarantine="${gh719_previous_only_home}/.codex/skills/.retired.vibeguard-quarantine.kept"
gh719_previous_only_transaction="${gh719_previous_only_home}/.codex/skills/.retired.vibeguard-transaction.kept.json"
gh719_current_owned="${gh719_previous_only_home}/.codex/skills/current/SKILL.md"
mkdir -p "${gh719_previous_only_home}/.vibeguard" "${gh719_previous_only_quarantine}" \
  "$(dirname "${gh719_current_owned}")"
printf 'managed\n' > "${gh719_previous_only_quarantine}/SKILL.md"
printf 'current-owned\n' > "${gh719_current_owned}"
python3 - "${gh719_previous_only_home}/.vibeguard/install-state.json" \
  "${gh719_previous_only_home}/.vibeguard/install-state.previous.json" \
  "${gh719_previous_only_transaction}" "${gh719_previous_only_dest}" \
  "${gh719_previous_only_quarantine}" "${gh719_current_owned}" <<'PY'
import hashlib, json, sys
current_path, previous_path, transaction_path, dest, quarantine, current_owned = sys.argv[1:]
entry = {"source": "skills/retired/SKILL.md", "type": "copy",
         "checksum": "sha256:" + hashlib.sha256(b"managed\n").hexdigest()}
files = {dest + "/SKILL.md": entry}
canonical = json.dumps(files, sort_keys=True, separators=(",", ":"))
digest = "sha256:" + hashlib.sha256(canonical.encode()).hexdigest()
record = {"version": 1, "quarantine": quarantine, "transaction": transaction_path,
          "source_prefix": "skills/retired", "tracked_digest": digest,
          "install_state_generation": 4, "nonce": "kept"}
transaction = dict(record, phase="committed", dest=dest)
json.dump(transaction, open(transaction_path, "w", encoding="utf-8"))
previous = {"version": 1, "generation": 4, "complete": True,
            "files": files,
            "disabled_skill_quarantines": {dest: record}}
current_entry = {"source": "skills/current/SKILL.md", "type": "copy",
                 "checksum": "sha256:" + hashlib.sha256(b"current-owned\n").hexdigest()}
current = {"version": 1, "generation": 5, "complete": True,
           "files": {current_owned: current_entry}}
json.dump(current, open(current_path, "w", encoding="utf-8"))
json.dump(previous, open(previous_path, "w", encoding="utf-8"))
PY
gh719_previous_only_current_seed="${TMP_HOME}/gh719-previous-only-current.seed.json"
gh719_previous_only_snapshot_seed="${TMP_HOME}/gh719-previous-only-snapshot.seed.json"
cp -p "${gh719_previous_only_home}/.vibeguard/install-state.json" \
  "${gh719_previous_only_current_seed}"
cp -p "${gh719_previous_only_home}/.vibeguard/install-state.previous.json" \
  "${gh719_previous_only_snapshot_seed}"
gh719_previous_only_current_hash="$(shasum -a 256 \
  "${gh719_previous_only_home}/.vibeguard/install-state.json" | awk '{print $1}')"
gh719_previous_only_snapshot_hash="$(shasum -a 256 \
  "${gh719_previous_only_home}/.vibeguard/install-state.previous.json" | awk '{print $1}')"
for gh719_state_failure in \
  VIBEGUARD_TEST_SETUP_STATE_INIT_FAILURE \
  VIBEGUARD_TEST_SETUP_STATE_WRITE_FAILURE; do
  gh719_state_failure_rc=0
  env "${gh719_state_failure}=1" HOME="${gh719_previous_only_home}" \
    VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" bash -c \
    'source "$1/scripts/lib/install-state.sh"; state_init core ""' _ "${REPO_DIR}" \
    >/dev/null 2>&1 || gh719_state_failure_rc=$?
  assert_cmd "${gh719_state_failure} is visible" test "${gh719_state_failure_rc}" -ne 0
  assert_cmd "${gh719_state_failure} preserves current state" test \
    "$(shasum -a 256 "${gh719_previous_only_home}/.vibeguard/install-state.json" | awk '{print $1}')" = \
    "${gh719_previous_only_current_hash}"
  assert_cmd "${gh719_state_failure} preserves previous-only locator" test \
    "$(shasum -a 256 "${gh719_previous_only_home}/.vibeguard/install-state.previous.json" | awk '{print $1}')" = \
    "${gh719_previous_only_snapshot_hash}"
done

for gh719_publish_failure in \
  VIBEGUARD_TEST_SETUP_STATE_AFTER_PREVIOUS_PUBLISH \
  VIBEGUARD_TEST_SETUP_STATE_CURRENT_PUBLISH_FAILURE; do
  cp -p "${gh719_previous_only_current_seed}" \
    "${gh719_previous_only_home}/.vibeguard/install-state.json"
  cp -p "${gh719_previous_only_snapshot_seed}" \
    "${gh719_previous_only_home}/.vibeguard/install-state.previous.json"
  gh719_publish_failure_rc=0
  env "${gh719_publish_failure}=1" HOME="${gh719_previous_only_home}" \
    VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" bash -c \
    'source "$1/scripts/lib/install-state.sh"; state_init core ""' _ "${REPO_DIR}" \
    >/dev/null 2>&1 || gh719_publish_failure_rc=$?
  assert_cmd "${gh719_publish_failure} is visible" test \
    "${gh719_publish_failure_rc}" -ne 0
  assert_cmd "${gh719_publish_failure} leaves a merged complete previous snapshot" python3 -c \
    'import json,sys; current=json.load(open(sys.argv[1])); previous=json.load(open(sys.argv[2])); retired,current_owned=sys.argv[3:]; assert current["generation"] == 5 and current["complete"] is True; assert retired not in current.get("disabled_skill_quarantines", {}); assert previous["generation"] == 5 and previous["complete"] is True; assert retired in previous["disabled_skill_quarantines"]; assert retired + "/SKILL.md" in previous["files"]; assert current_owned in previous["files"]' \
    "${gh719_previous_only_home}/.vibeguard/install-state.json" \
    "${gh719_previous_only_home}/.vibeguard/install-state.previous.json" \
    "${gh719_previous_only_dest}" "${gh719_current_owned}"
  assert_cmd "${gh719_publish_failure} leaves canonical state preflight-safe" env \
    HOME="${gh719_previous_only_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
    bash -c 'source "$1/scripts/lib/install-state.sh"; state_preflight' _ "${REPO_DIR}"
  HOME="${gh719_previous_only_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" bash -c \
    'source "$1/scripts/lib/install-state.sh"; state_init core ""' _ "${REPO_DIR}"
  assert_cmd "${gh719_publish_failure} retries with canonical ownership and generation" python3 -c \
    'import json,sys; current=json.load(open(sys.argv[1])); previous=json.load(open(sys.argv[2])); retired,current_owned=sys.argv[3:]; assert current["generation"] == 6 and current["complete"] is False; assert previous["generation"] == 5 and previous["complete"] is True; assert retired in current["disabled_skill_quarantines"] and retired in previous["disabled_skill_quarantines"]; assert retired + "/SKILL.md" in current["files"] and retired + "/SKILL.md" in previous["files"]; assert current_owned in previous["files"]' \
    "${gh719_previous_only_home}/.vibeguard/install-state.json" \
    "${gh719_previous_only_home}/.vibeguard/install-state.previous.json" \
    "${gh719_previous_only_dest}" "${gh719_current_owned}"
done
HOME="${gh719_previous_only_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" bash -c \
  'source "$1/scripts/lib/install-state.sh"; state_init core ""' _ "${REPO_DIR}"
assert_cmd "state init preserves a previous-only active quarantine" python3 -c \
  'import json,sys; d=json.load(open(sys.argv[1])); assert sys.argv[2] in d["disabled_skill_quarantines"]; assert sys.argv[2] + "/SKILL.md" in d["files"]' \
  "${gh719_previous_only_home}/.vibeguard/install-state.json" "${gh719_previous_only_dest}"

for gh719_legacy_artifact in \
  "${gh719_previous_only_home}/.vibeguard/install-state.previous.json.backup.stale" \
  "${gh719_previous_only_home}/.vibeguard/install-state.json.next.stale"; do
  cp -p "${gh719_previous_only_snapshot_seed}" "${gh719_legacy_artifact}"
  gh719_legacy_artifact_rc=0
  gh719_legacy_artifact_out="$(
    HOME="${gh719_previous_only_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" bash -c \
      'source "$1/scripts/lib/install-state.sh"; state_preflight' _ "${REPO_DIR}" 2>&1
  )" || gh719_legacy_artifact_rc=$?
  assert_cmd "legacy publish artifact is not silently ignored" test \
    "${gh719_legacy_artifact_rc}" -ne 0
  assert_contains "${gh719_legacy_artifact_out}" "requires explicit recovery" \
    "legacy publish artifact reports fail-closed recovery requirement"
  rm -f "${gh719_legacy_artifact}"
done

gh719_order_home="${TMP_HOME}/gh719-generation-order-home"
mkdir -p "${gh719_order_home}/.vibeguard"
printf '%s\n' '{"version":1,"generation":3,"complete":true,"files":{}}' \
  > "${gh719_order_home}/.vibeguard/install-state.json"
printf '%s\n' '{"version":1,"generation":5,"complete":true,"files":{}}' \
  > "${gh719_order_home}/.vibeguard/install-state.previous.json"
gh719_order_rc=0
HOME="${gh719_order_home}" VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" bash -c '
  source "$1/scripts/lib/install-state.sh"
  state_preflight
' _ "${REPO_DIR}" >/dev/null 2>&1 || gh719_order_rc=$?
assert_cmd "generation ordering fails during preflight" test "${gh719_order_rc}" -ne 0

assert_cmd "disabled skill source reports _VG_CONFIG_FILE" env \
  _VG_CONFIG_FILE=/custom/internal.json \
  VIBEGUARD_CONFIG_FILE=/ignored/user.json \
  VIBEGUARD_LOG_DIR=/ignored/log bash -c '
    source "$1/scripts/setup/lib.sh"
    [[ "$(disabled_skills_source_label)" == "/custom/internal.json" ]]
  ' _ "${REPO_DIR}"
assert_cmd "disabled skill source prefers VG_INTERNAL_CONFIG_FILE" env \
  VG_INTERNAL_CONFIG_FILE=/custom/internal-v2.json \
  _VG_CONFIG_FILE=/deprecated/internal.json \
  VIBEGUARD_CONFIG_FILE=/ignored/user.json bash -c '
    source "$1/scripts/setup/lib.sh"
    [[ "$(disabled_skills_source_label)" == "/custom/internal-v2.json" ]]
  ' _ "${REPO_DIR}"
assert_cmd "disabled skill source reports temporary list override first" env \
  VIBEGUARD_DISABLED_SKILLS=plan-flow \
  _VG_CONFIG_FILE=/ignored/internal.json bash -c '
    source "$1/scripts/setup/lib.sh"
    [[ "$(disabled_skills_source_label)" == "temporary VIBEGUARD_DISABLED_SKILLS override" ]]
  ' _ "${REPO_DIR}"
gh719_project_config="${gh719_order_home}/project-vibeguard.json"
printf '%s\n' '{"disabled_skills":["plan-flow"]}' > "${gh719_project_config}"
assert_cmd "disabled skill source reports project overlay" env \
  VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
  VIBEGUARD_PROJECT_CONFIG="${gh719_project_config}" \
  VIBEGUARD_CONFIG_FILE=/ignored/user.json bash -c '
    source "$1/scripts/setup/lib.sh"
    [[ "$(disabled_skills_source_label)" == "$2" ]]
  ' _ "${REPO_DIR}" "${gh719_project_config}"
gh719_invalid_project_config="${gh719_order_home}/invalid-project-vibeguard.json"
printf '%s\n' '{' > "${gh719_invalid_project_config}"
gh719_invalid_project_out=""
if gh719_invalid_project_out="$(HOME="${gh719_order_home}" \
  VIBEGUARD_SETUP_RUNTIME="${gh719_runtime}" \
  VIBEGUARD_PROJECT_CONFIG="${gh719_invalid_project_config}" bash -c '
    source "$1/scripts/setup/lib.sh"
    disabled_skills
  ' _ "${REPO_DIR}" 2>&1)"; then
  red "invalid project disabled_skills config unexpectedly succeeded"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
else
  green "invalid project disabled_skills config fails visibly"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
fi
assert_contains "${gh719_invalid_project_out}" \
  "cannot read disabled_skills from ${gh719_invalid_project_config}" \
  "invalid project disabled_skills diagnostic preserves project path"
assert_cmd "disabled skill source reports VIBEGUARD_CONFIG_FILE" env \
  VIBEGUARD_CONFIG_FILE=/custom/user.json bash -c '
    source "$1/scripts/setup/lib.sh"
    [[ "$(disabled_skills_source_label)" == "/custom/user.json" ]]
  ' _ "${REPO_DIR}"
assert_cmd "disabled skill source reports VIBEGUARD_LOG_DIR config" env \
  VIBEGUARD_LOG_DIR=/custom/log bash -c '
    source "$1/scripts/setup/lib.sh"
    [[ "$(disabled_skills_source_label)" == "/custom/log/config.json" ]]
  ' _ "${REPO_DIR}"

# GH719 clean lifecycle: the canonical lock must be released while the pinned
# runtime is still available, including on the failure path after
# clean_vibeguard_home has already deleted the installed runtime. The fixture
# installs only the managed runtime so that ~/.vibeguard/installed/bin is the
# sole clean-time runtime candidate.
gh719_seed_installed_runtime() {
  local target_home="$1"
  mkdir -p "${target_home}/.vibeguard/installed/bin"
  cp "${gh719_runtime}" "${target_home}/.vibeguard/installed/bin/vibeguard-runtime"
  chmod +x "${target_home}/.vibeguard/installed/bin/vibeguard-runtime"
  printf '%s\n' 'must-survive' > "${target_home}/.vibeguard/run-hook.sh"
}

gh719_pinned_clean_home="${TMP_HOME}/gh719-pinned-clean-home"
gh719_seed_installed_runtime "${gh719_pinned_clean_home}"
# An unowned scheduler file makes clean_scheduled_gc fail after the installed
# tree, and therefore the installed runtime, has already been removed.
mkdir -p "${gh719_pinned_clean_home}/.config/systemd/user"
printf '%s\n' 'not-vibeguard' \
  > "${gh719_pinned_clean_home}/.config/systemd/user/vibeguard-gc.service"
gh719_pinned_clean_rc=0
gh719_pinned_clean_out="$(
  HOME="${gh719_pinned_clean_home}" VIBEGUARD_SETUP_SKIP_REPO_RUNTIME=1 \
    bash "${REPO_DIR}/setup.sh" --clean 2>&1
)" || gh719_pinned_clean_rc=$?
assert_cmd "unowned scheduler file fails the clean" test "${gh719_pinned_clean_rc}" -ne 0
assert_cmd "failed clean removed the installed runtime it depended on" test \
  ! -e "${gh719_pinned_clean_home}/.vibeguard/installed/bin/vibeguard-runtime"
assert_cmd "failed clean still releases the canonical setup lock" test \
  ! -e "${gh719_pinned_clean_home}/.vibeguard/setup.lock"
assert_not_contains "${gh719_pinned_clean_out}" "failed to release the VibeGuard setup lock" \
  "failed clean releases the lock before discarding the pinned runtime"

gh719_ok_clean_home="${TMP_HOME}/gh719-ok-clean-home"
gh719_seed_installed_runtime "${gh719_ok_clean_home}"
gh719_ok_clean_rc=0
HOME="${gh719_ok_clean_home}" VIBEGUARD_SETUP_SKIP_REPO_RUNTIME=1 \
  bash "${REPO_DIR}/setup.sh" --clean >/dev/null 2>&1 || gh719_ok_clean_rc=$?
assert_cmd "clean succeeds with only the installed runtime available" test \
  "${gh719_ok_clean_rc}" -eq 0
assert_cmd "successful clean leaves no canonical setup lock" test \
  ! -e "${gh719_ok_clean_home}/.vibeguard/setup.lock"
