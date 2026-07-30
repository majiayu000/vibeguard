standalone_alt_repo="${TMP_HOME}/standalone-systemd-alt-repo"
mkdir -p "${standalone_alt_repo}/scripts/gc"
printf '#!/usr/bin/env bash\nexit 0\n' \
  > "${standalone_alt_repo}/scripts/gc/gc-scheduled.sh"
chmod +x "${standalone_alt_repo}/scripts/gc/gc-scheduled.sh"
: > "${standalone_fresh_log}"
assert_cmd "standalone refresh supports changed rendered repository path" \
  env HOME="${standalone_fresh_home}" \
  PATH="${standalone_systemd_bin}:${PATH}" \
  VIBEGUARD_REPO_DIR="${standalone_alt_repo}" \
  VIBEGUARD_TEST_SYSTEMCTL_LOG="${standalone_fresh_log}" \
  bash "${REPO_DIR}/scripts/install-systemd.sh"
standalone_refreshed_service_sha="$(
  shasum -a 256 \
    "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.service" \
    | awk '{print $1}'
)"
standalone_refreshed_timer_sha="$(
  shasum -a 256 \
    "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.timer" \
    | awk '{print $1}'
)"
assert_cmd "changed-path refresh updates units and exact receipt hashes" bash -c \
  'grep -qF "$4" "$1" \
    && grep -qFx "service_sha256=$5" "$3" \
    && grep -qFx "timer_sha256=$6" "$3"' _ \
  "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.service" \
  "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.timer" \
  "${standalone_fresh_receipt}" "${standalone_alt_repo}" \
  "${standalone_refreshed_service_sha}" \
  "${standalone_refreshed_timer_sha}"
assert_cmd "next standalone run accepts refreshed ownership receipt" \
  env HOME="${standalone_fresh_home}" \
  PATH="${standalone_systemd_bin}:${PATH}" \
  VIBEGUARD_REPO_DIR="${standalone_alt_repo}" \
  VIBEGUARD_TEST_SYSTEMCTL_LOG="${standalone_fresh_log}" \
  bash "${REPO_DIR}/scripts/install-systemd.sh"

standalone_rollback_repo="${TMP_HOME}/standalone-systemd-rollback-repo"
standalone_rollback_marker="${TMP_HOME}/standalone-systemd-enable-failed-once"
mkdir -p "${standalone_rollback_repo}/scripts/gc"
printf '#!/usr/bin/env bash\nexit 0\n' \
  > "${standalone_rollback_repo}/scripts/gc/gc-scheduled.sh"
chmod +x "${standalone_rollback_repo}/scripts/gc/gc-scheduled.sh"
standalone_refresh_before="$(
  shasum -a 256 \
    "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.service" \
    "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.timer" \
    "${standalone_fresh_receipt}"
)"
standalone_refresh_fail_rc=0
env HOME="${standalone_fresh_home}" \
  PATH="${standalone_systemd_bin}:${PATH}" \
  VIBEGUARD_REPO_DIR="${standalone_rollback_repo}" \
  VIBEGUARD_TEST_SYSTEMCTL_LOG="${standalone_fresh_log}" \
  VIBEGUARD_TEST_SYSTEMD_ENABLE_FAIL_ONCE=1 \
  VIBEGUARD_TEST_SYSTEMD_FAIL_MARKER="${standalone_rollback_marker}" \
  bash "${REPO_DIR}/scripts/install-systemd.sh" >/dev/null 2>&1 \
  || standalone_refresh_fail_rc=$?
assert_cmd "failed standalone activation returns nonzero after rollback" \
  test "${standalone_refresh_fail_rc}" -ne 0
assert_cmd "failed standalone refresh restores units and receipt byte-for-byte" bash -c \
  'test "$(shasum -a 256 "$1" "$2" "$3")" = "$4"' _ \
  "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.service" \
  "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.timer" \
  "${standalone_fresh_receipt}" "${standalone_refresh_before}"
