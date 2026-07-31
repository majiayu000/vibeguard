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

post_activation_hash_bin="${TMP_HOME}/standalone-systemd-post-activation-hash-bin"
post_activation_real_sha256sum="$(command -v sha256sum || true)"
post_activation_real_shasum="$(command -v shasum)"
mkdir -p "${post_activation_hash_bin}"
cat > "${post_activation_hash_bin}/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Linux
SH
cat > "${post_activation_hash_bin}/systemctl" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "--user" ]] && shift
case "${1:-}" in
  daemon-reload)
    if [[ "${VIBEGUARD_TEST_SYSTEMD_DAEMON_RELOAD_FAIL_ONCE:-0}" == "1" \
      && ! -e "${VIBEGUARD_TEST_SYSTEMD_DAEMON_RELOAD_FAIL_MARKER}" ]]; then
      touch "${VIBEGUARD_TEST_SYSTEMD_DAEMON_RELOAD_FAIL_MARKER}"
      exit 91
    fi
    exit 0
    ;;
  list-timers)
    exit 0
    ;;
  enable)
    if [[ "${2:-}" == "--runtime" ]]; then
      touch "${VIBEGUARD_TEST_SYSTEMD_ENABLED_RUNTIME}"
      rm -f -- "${VIBEGUARD_TEST_SYSTEMD_ENABLED}"
      exit 0
    fi
    touch "${VIBEGUARD_TEST_SYSTEMD_ENABLED}"
    if [[ -n "${VIBEGUARD_TEST_SYSTEMD_ENABLED_RUNTIME:-}" ]]; then
      rm -f -- "${VIBEGUARD_TEST_SYSTEMD_ENABLED_RUNTIME}"
    fi
    if [[ "${2:-}" == "--now" ]]; then
      touch "${VIBEGUARD_TEST_SYSTEMD_ACTIVE}" \
        "${VIBEGUARD_TEST_HASH_ACTIVATED}"
    fi
    exit 0
    ;;
  start)
    if [[ "${2:-}" == "vibeguard-gc.timer" ]]; then
      touch "${VIBEGUARD_TEST_SYSTEMD_ACTIVE}"
    elif [[ "${2:-}" == "vibeguard-gc.service" ]]; then
      touch "${VIBEGUARD_TEST_SYSTEMD_SERVICE_ACTIVE}"
    fi
    exit 0
    ;;
  stop)
    if [[ "${2:-}" == "vibeguard-gc.timer" ]]; then
      rm -f -- "${VIBEGUARD_TEST_SYSTEMD_ACTIVE}"
    elif [[ "${2:-}" == "vibeguard-gc.service" ]]; then
      rm -f -- "${VIBEGUARD_TEST_SYSTEMD_SERVICE_ACTIVE}"
    fi
    exit 0
    ;;
  disable)
    rm -f -- "${VIBEGUARD_TEST_SYSTEMD_ENABLED}"
    if [[ -n "${VIBEGUARD_TEST_SYSTEMD_ENABLED_RUNTIME:-}" ]]; then
      rm -f -- "${VIBEGUARD_TEST_SYSTEMD_ENABLED_RUNTIME}"
    fi
    exit 0
    ;;
  is-active)
    if [[ "${2:-}" == "vibeguard-gc.timer" \
      && -e "${VIBEGUARD_TEST_SYSTEMD_ACTIVE}" ]]; then
      printf 'active\n'
      exit 0
    fi
    if [[ "${2:-}" == "vibeguard-gc.service" \
      && -e "${VIBEGUARD_TEST_SYSTEMD_SERVICE_ACTIVE}" ]]; then
      printf 'active\n'
      exit 0
    fi
    printf 'inactive\n'
    exit 3
    ;;
  is-enabled)
    if [[ -n "${VIBEGUARD_TEST_SYSTEMD_ENABLED_RUNTIME:-}" \
      && -e "${VIBEGUARD_TEST_SYSTEMD_ENABLED_RUNTIME}" ]]; then
      printf 'enabled-runtime\n'
      exit 0
    fi
    if [[ -e "${VIBEGUARD_TEST_SYSTEMD_ENABLED}" ]]; then
      printf 'enabled\n'
      exit 0
    fi
    printf 'disabled\n'
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
SH
cat > "${post_activation_hash_bin}/sha256sum" <<'SH'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last="${arg}"; done
if [[ -e "${VIBEGUARD_TEST_HASH_ACTIVATED}" \
  && "${last}" == "${VIBEGUARD_TEST_HASH_FAIL_PATH}" ]]; then
  exit 91
fi
if [[ -n "${VIBEGUARD_TEST_REAL_SHA256SUM}" ]]; then
  exec "${VIBEGUARD_TEST_REAL_SHA256SUM}" "$@"
fi
exec "${VIBEGUARD_TEST_REAL_SHASUM}" -a 256 "$@"
SH
cat > "${post_activation_hash_bin}/shasum" <<'SH'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last="${arg}"; done
if [[ -e "${VIBEGUARD_TEST_HASH_ACTIVATED}" \
  && "${last}" == "${VIBEGUARD_TEST_HASH_FAIL_PATH}" ]]; then
  exit 91
fi
exec "${VIBEGUARD_TEST_REAL_SHASUM}" "$@"
SH
chmod +x \
  "${post_activation_hash_bin}/uname" \
  "${post_activation_hash_bin}/systemctl" \
  "${post_activation_hash_bin}/sha256sum" \
  "${post_activation_hash_bin}/shasum"

post_activation_hash_env=(
  PATH="${post_activation_hash_bin}:${PATH}"
  VIBEGUARD_TEST_REAL_SHA256SUM="${post_activation_real_sha256sum}"
  VIBEGUARD_TEST_REAL_SHASUM="${post_activation_real_shasum}"
)

fresh_hash_home="${TMP_HOME}/standalone-systemd-fresh-hash-failure-home"
fresh_hash_service="${fresh_hash_home}/.config/systemd/user/vibeguard-gc.service"
fresh_hash_timer="${fresh_hash_home}/.config/systemd/user/vibeguard-gc.timer"
fresh_hash_receipt="${fresh_hash_home}/.vibeguard/scheduler-ownership"
fresh_hash_active="${fresh_hash_home}/.systemctl-vibeguard-gc-active"
fresh_hash_enabled="${fresh_hash_home}/.systemctl-vibeguard-gc-enabled"
fresh_hash_activated="${fresh_hash_home}/.systemctl-vibeguard-gc-activated"
mkdir -p "${fresh_hash_home}"
fresh_hash_rc=0
fresh_hash_out="$(
  env HOME="${fresh_hash_home}" "${post_activation_hash_env[@]}" \
    VIBEGUARD_TEST_SYSTEMD_ACTIVE="${fresh_hash_active}" \
    VIBEGUARD_TEST_SYSTEMD_ENABLED="${fresh_hash_enabled}" \
    VIBEGUARD_TEST_HASH_ACTIVATED="${fresh_hash_activated}" \
    VIBEGUARD_TEST_HASH_FAIL_PATH="${fresh_hash_service}" \
    bash "${REPO_DIR}/scripts/install-systemd.sh" 2>&1
)" || fresh_hash_rc=$?
assert_cmd "fresh post-activation hash failure returns nonzero" \
  test "${fresh_hash_rc}" -ne 0
assert_contains "${fresh_hash_out}" \
  "failed to hash installed systemd units; restored the previous scheduler state" \
  "fresh post-activation hash failure reports successful rollback"
assert_cmd "fresh hash rollback removes units and receipt and deactivates scheduler" bash -c \
  'test ! -e "$1" && test ! -e "$2" && test ! -e "$3" \
    && test ! -e "$4" && test ! -e "$5"' _ \
  "${fresh_hash_service}" "${fresh_hash_timer}" "${fresh_hash_receipt}" \
  "${fresh_hash_active}" "${fresh_hash_enabled}"

refresh_hash_home="${TMP_HOME}/standalone-systemd-refresh-hash-failure-home"
refresh_hash_service="${refresh_hash_home}/.config/systemd/user/vibeguard-gc.service"
refresh_hash_timer="${refresh_hash_home}/.config/systemd/user/vibeguard-gc.timer"
refresh_hash_receipt="${refresh_hash_home}/.vibeguard/scheduler-ownership"
refresh_hash_active="${refresh_hash_home}/.systemctl-vibeguard-gc-active"
refresh_hash_enabled="${refresh_hash_home}/.systemctl-vibeguard-gc-enabled"
refresh_hash_activated="${refresh_hash_home}/.systemctl-vibeguard-gc-activated"
mkdir -p "${refresh_hash_home}"
env HOME="${refresh_hash_home}" "${post_activation_hash_env[@]}" \
  VIBEGUARD_TEST_SYSTEMD_ACTIVE="${refresh_hash_active}" \
  VIBEGUARD_TEST_SYSTEMD_ENABLED="${refresh_hash_enabled}" \
  VIBEGUARD_TEST_HASH_ACTIVATED="${refresh_hash_activated}" \
  VIBEGUARD_TEST_HASH_FAIL_PATH="${refresh_hash_home}/not-this-run" \
  bash "${REPO_DIR}/scripts/install-systemd.sh" >/dev/null
rm -f -- "${refresh_hash_activated}"
refresh_hash_before="$(
  shasum -a 256 \
    "${refresh_hash_service}" "${refresh_hash_timer}" "${refresh_hash_receipt}"
)"
refresh_hash_rc=0
refresh_hash_out="$(
  env HOME="${refresh_hash_home}" "${post_activation_hash_env[@]}" \
    VIBEGUARD_REPO_DIR="${standalone_alt_repo}" \
    VIBEGUARD_TEST_SYSTEMD_ACTIVE="${refresh_hash_active}" \
    VIBEGUARD_TEST_SYSTEMD_ENABLED="${refresh_hash_enabled}" \
    VIBEGUARD_TEST_HASH_ACTIVATED="${refresh_hash_activated}" \
    VIBEGUARD_TEST_HASH_FAIL_PATH="${refresh_hash_timer}" \
    bash "${REPO_DIR}/scripts/install-systemd.sh" 2>&1
)" || refresh_hash_rc=$?
assert_cmd "refresh post-activation hash failure returns nonzero" \
  test "${refresh_hash_rc}" -ne 0
assert_contains "${refresh_hash_out}" \
  "failed to hash installed systemd units; restored the previous scheduler state" \
  "refresh post-activation hash failure reports successful rollback"
assert_cmd "refresh hash rollback restores units and receipt byte-for-byte" bash -c \
  'test "$(shasum -a 256 "$1" "$2" "$3")" = "$4"' _ \
  "${refresh_hash_service}" "${refresh_hash_timer}" \
  "${refresh_hash_receipt}" "${refresh_hash_before}"
assert_cmd "refresh hash rollback restores prior active and enabled state" bash -c \
  'test -e "$1" && test -e "$2"' _ \
  "${refresh_hash_active}" "${refresh_hash_enabled}"

rm -f -- \
  "${refresh_hash_active}" \
  "${refresh_hash_enabled}" \
  "${refresh_hash_activated}"
inactive_refresh_before="$(
  shasum -a 256 \
    "${refresh_hash_service}" "${refresh_hash_timer}" "${refresh_hash_receipt}"
)"
inactive_refresh_rc=0
inactive_refresh_out="$(
  env HOME="${refresh_hash_home}" "${post_activation_hash_env[@]}" \
    VIBEGUARD_REPO_DIR="${standalone_rollback_repo}" \
    VIBEGUARD_TEST_SYSTEMD_ACTIVE="${refresh_hash_active}" \
    VIBEGUARD_TEST_SYSTEMD_ENABLED="${refresh_hash_enabled}" \
    VIBEGUARD_TEST_HASH_ACTIVATED="${refresh_hash_activated}" \
    VIBEGUARD_TEST_HASH_FAIL_PATH="${refresh_hash_timer}" \
    bash "${REPO_DIR}/scripts/install-systemd.sh" 2>&1
)" || inactive_refresh_rc=$?
assert_cmd "inactive disabled refresh hash failure returns nonzero" \
  test "${inactive_refresh_rc}" -ne 0
assert_contains "${inactive_refresh_out}" \
  "failed to hash installed systemd units; restored the previous scheduler state" \
  "inactive disabled refresh reports successful rollback"
assert_cmd "inactive disabled refresh restores units and receipt byte-for-byte" bash -c \
  'test "$(shasum -a 256 "$1" "$2" "$3")" = "$4"' _ \
  "${refresh_hash_service}" "${refresh_hash_timer}" \
  "${refresh_hash_receipt}" "${inactive_refresh_before}"
assert_cmd "inactive disabled refresh does not activate or enable timer" bash -c \
  'test ! -e "$1" && test ! -e "$2"' _ \
  "${refresh_hash_active}" "${refresh_hash_enabled}"

runtime_refresh_home="${TMP_HOME}/standalone-systemd-runtime-refresh-home"
runtime_refresh_service="${runtime_refresh_home}/.config/systemd/user/vibeguard-gc.service"
runtime_refresh_timer="${runtime_refresh_home}/.config/systemd/user/vibeguard-gc.timer"
runtime_refresh_receipt="${runtime_refresh_home}/.vibeguard/scheduler-ownership"
runtime_refresh_active="${runtime_refresh_home}/.systemctl-vibeguard-gc-active"
runtime_refresh_service_active="${runtime_refresh_home}/.systemctl-vibeguard-gc-service-active"
runtime_refresh_enabled="${runtime_refresh_home}/.systemctl-vibeguard-gc-enabled"
runtime_refresh_enabled_runtime="${runtime_refresh_home}/.systemctl-vibeguard-gc-enabled-runtime"
runtime_refresh_activated="${runtime_refresh_home}/.systemctl-vibeguard-gc-activated"
mkdir -p "${runtime_refresh_home}"
env HOME="${runtime_refresh_home}" "${post_activation_hash_env[@]}" \
  VIBEGUARD_TEST_SYSTEMD_ACTIVE="${runtime_refresh_active}" \
  VIBEGUARD_TEST_SYSTEMD_SERVICE_ACTIVE="${runtime_refresh_service_active}" \
  VIBEGUARD_TEST_SYSTEMD_ENABLED="${runtime_refresh_enabled}" \
  VIBEGUARD_TEST_SYSTEMD_ENABLED_RUNTIME="${runtime_refresh_enabled_runtime}" \
  VIBEGUARD_TEST_HASH_ACTIVATED="${runtime_refresh_activated}" \
  VIBEGUARD_TEST_HASH_FAIL_PATH="${runtime_refresh_home}/not-this-run" \
  bash "${REPO_DIR}/scripts/install-systemd.sh" >/dev/null
rm -f -- "${runtime_refresh_enabled}" "${runtime_refresh_activated}"
touch "${runtime_refresh_enabled_runtime}"
runtime_refresh_before="$(
  shasum -a 256 \
    "${runtime_refresh_service}" "${runtime_refresh_timer}" \
    "${runtime_refresh_receipt}"
)"
runtime_refresh_rc=0
runtime_refresh_out="$(
  env HOME="${runtime_refresh_home}" "${post_activation_hash_env[@]}" \
    VIBEGUARD_REPO_DIR="${standalone_alt_repo}" \
    VIBEGUARD_TEST_SYSTEMD_ACTIVE="${runtime_refresh_active}" \
    VIBEGUARD_TEST_SYSTEMD_SERVICE_ACTIVE="${runtime_refresh_service_active}" \
    VIBEGUARD_TEST_SYSTEMD_ENABLED="${runtime_refresh_enabled}" \
    VIBEGUARD_TEST_SYSTEMD_ENABLED_RUNTIME="${runtime_refresh_enabled_runtime}" \
    VIBEGUARD_TEST_HASH_ACTIVATED="${runtime_refresh_activated}" \
    VIBEGUARD_TEST_HASH_FAIL_PATH="${runtime_refresh_timer}" \
    bash "${REPO_DIR}/scripts/install-systemd.sh" 2>&1
)" || runtime_refresh_rc=$?
assert_cmd "runtime-enabled refresh reaches the intentional hash failure" \
  grep -qF "failed to hash installed systemd units" <<< "${runtime_refresh_out}"
assert_cmd "runtime-enabled refresh hash failure returns nonzero" \
  test "${runtime_refresh_rc}" -ne 0
assert_cmd "runtime-enabled refresh restores units and receipt byte-for-byte" bash -c \
  'test "$(shasum -a 256 "$1" "$2" "$3")" = "$4"' _ \
  "${runtime_refresh_service}" "${runtime_refresh_timer}" \
  "${runtime_refresh_receipt}" "${runtime_refresh_before}"
assert_cmd "runtime-enabled refresh restores runtime enablement exactly" bash -c \
  'test -e "$1" && test ! -e "$2"' _ \
  "${runtime_refresh_enabled_runtime}" "${runtime_refresh_enabled}"

remove_rollback_home="${TMP_HOME}/standalone-systemd-remove-rollback-home"
remove_rollback_service="${remove_rollback_home}/.config/systemd/user/vibeguard-gc.service"
remove_rollback_timer="${remove_rollback_home}/.config/systemd/user/vibeguard-gc.timer"
remove_rollback_receipt="${remove_rollback_home}/.vibeguard/scheduler-ownership"
remove_rollback_active="${remove_rollback_home}/.systemctl-vibeguard-gc-active"
remove_rollback_service_active="${remove_rollback_home}/.systemctl-vibeguard-gc-service-active"
remove_rollback_enabled="${remove_rollback_home}/.systemctl-vibeguard-gc-enabled"
remove_rollback_enabled_runtime="${remove_rollback_home}/.systemctl-vibeguard-gc-enabled-runtime"
remove_rollback_activated="${remove_rollback_home}/.systemctl-vibeguard-gc-activated"
remove_rollback_reload_marker="${remove_rollback_home}/.systemctl-daemon-reload-failed"
mkdir -p "${remove_rollback_home}"
env HOME="${remove_rollback_home}" "${post_activation_hash_env[@]}" \
  VIBEGUARD_TEST_SYSTEMD_ACTIVE="${remove_rollback_active}" \
  VIBEGUARD_TEST_SYSTEMD_SERVICE_ACTIVE="${remove_rollback_service_active}" \
  VIBEGUARD_TEST_SYSTEMD_ENABLED="${remove_rollback_enabled}" \
  VIBEGUARD_TEST_SYSTEMD_ENABLED_RUNTIME="${remove_rollback_enabled_runtime}" \
  VIBEGUARD_TEST_HASH_ACTIVATED="${remove_rollback_activated}" \
  VIBEGUARD_TEST_HASH_FAIL_PATH="${remove_rollback_home}/not-this-run" \
  bash "${REPO_DIR}/scripts/install-systemd.sh" >/dev/null
touch "${remove_rollback_service_active}"
remove_rollback_before="$(
  shasum -a 256 \
    "${remove_rollback_service}" "${remove_rollback_timer}" \
    "${remove_rollback_receipt}"
)"
remove_rollback_rc=0
env HOME="${remove_rollback_home}" "${post_activation_hash_env[@]}" \
  VIBEGUARD_TEST_SYSTEMD_ACTIVE="${remove_rollback_active}" \
  VIBEGUARD_TEST_SYSTEMD_SERVICE_ACTIVE="${remove_rollback_service_active}" \
  VIBEGUARD_TEST_SYSTEMD_ENABLED="${remove_rollback_enabled}" \
  VIBEGUARD_TEST_SYSTEMD_ENABLED_RUNTIME="${remove_rollback_enabled_runtime}" \
  VIBEGUARD_TEST_HASH_ACTIVATED="${remove_rollback_activated}" \
  VIBEGUARD_TEST_HASH_FAIL_PATH="${remove_rollback_home}/not-this-run" \
  VIBEGUARD_TEST_SYSTEMD_DAEMON_RELOAD_FAIL_ONCE=1 \
  VIBEGUARD_TEST_SYSTEMD_DAEMON_RELOAD_FAIL_MARKER="${remove_rollback_reload_marker}" \
  bash "${REPO_DIR}/scripts/install-systemd.sh" --remove >/dev/null 2>&1 \
  || remove_rollback_rc=$?
assert_cmd "remove daemon-reload failure returns nonzero" \
  test "${remove_rollback_rc}" -ne 0
assert_cmd "remove rollback restores units and receipt byte-for-byte" bash -c \
  'test "$(shasum -a 256 "$1" "$2" "$3")" = "$4"' _ \
  "${remove_rollback_service}" "${remove_rollback_timer}" \
  "${remove_rollback_receipt}" "${remove_rollback_before}"
assert_cmd "remove rollback restores timer, service, and enablement state" bash -c \
  'test -e "$1" && test -e "$2" && test -e "$3"' _ \
  "${remove_rollback_active}" "${remove_rollback_service_active}" \
  "${remove_rollback_enabled}"
