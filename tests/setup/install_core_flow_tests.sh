header "hooks manifest"
assert_cmd "hooks manifest validates" bash "${REPO_DIR}/scripts/ci/validate-hooks-manifest.sh"
assert_cmd "hooks/CLAUDE.md table is generated from manifest" bash "${REPO_DIR}/scripts/setup/regenerate-hooks-from-manifest.sh" --check
assert_cmd "Codex helper specs come from hook manifest" bash -c "python3 '${HOOKS_MANIFEST_HELPER}' codex-specs | grep -q 'vibeguard-pre-bash-guard.sh'"

header "scheduled GC templates"
assert_cmd "scheduled GC script exists at canonical path" test -x "${REPO_DIR}/scripts/gc/gc-scheduled.sh"
assert_cmd "launchd plist points to canonical GC script path" grep -q "__VIBEGUARD_DIR__/scripts/gc/gc-scheduled.sh" "${REPO_DIR}/scripts/setup/com.vibeguard.gc.plist"
assert_cmd "systemd service points to canonical GC script path" grep -q "__VIBEGUARD_DIR__/scripts/gc/gc-scheduled.sh" "${REPO_DIR}/scripts/systemd/vibeguard-gc.service"
assert_cmd "systemd installer chmods canonical GC script path" grep -q 'scripts/gc/gc-scheduled.sh' "${REPO_DIR}/scripts/install-systemd.sh"
assert_cmd "scheduled GC installers do not reference retired root path" bash -c "! grep -q 'scripts/gc-scheduled.sh' '${REPO_DIR}/scripts/setup/com.vibeguard.gc.plist' '${REPO_DIR}/scripts/systemd/vibeguard-gc.service' '${REPO_DIR}/scripts/install-systemd.sh'"

standalone_systemd_bin="${TMP_HOME}/standalone-systemd-bin"
mkdir -p "${standalone_systemd_bin}"
cat > "${standalone_systemd_bin}/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Linux
SH
cat > "${standalone_systemd_bin}/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${VIBEGUARD_TEST_SYSTEMCTL_LOG}"
[[ "${1:-}" == "--user" ]] && shift
case "${1:-}" in
  stop|disable|daemon-reload|list-timers)
    exit 0
    ;;
  is-active)
    printf 'inactive\n'
    exit 3
    ;;
  is-enabled)
    printf 'disabled\n'
    exit 1
    ;;
  enable)
    if [[ "${VIBEGUARD_TEST_SYSTEMD_ENABLE_FAIL_ONCE:-0}" == "1" \
      && ! -e "${VIBEGUARD_TEST_SYSTEMD_FAIL_MARKER}" ]]; then
      : > "${VIBEGUARD_TEST_SYSTEMD_FAIL_MARKER}"
      exit 1
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "${standalone_systemd_bin}/uname" "${standalone_systemd_bin}/systemctl"

standalone_fresh_home="${TMP_HOME}/standalone-systemd-fresh-home"
standalone_fresh_log="${TMP_HOME}/standalone-systemd-fresh-systemctl.log"
mkdir -p "${standalone_fresh_home}"
: > "${standalone_fresh_log}"
assert_cmd "documented systemd installer preserves fresh-install behavior" \
  env HOME="${standalone_fresh_home}" \
  PATH="${standalone_systemd_bin}:${PATH}" \
  VIBEGUARD_TEST_SYSTEMCTL_LOG="${standalone_fresh_log}" \
  bash "${REPO_DIR}/scripts/install-systemd.sh"
assert_cmd "fresh standalone install writes both systemd units" bash -c \
  'test -f "$1" && test -f "$2"' _ \
  "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.service" \
  "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.timer"

standalone_fresh_receipt="${standalone_fresh_home}/.vibeguard/scheduler-ownership"
standalone_fresh_service_sha="$(
  shasum -a 256 \
    "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.service" \
    | awk '{print $1}'
)"
standalone_fresh_timer_sha="$(
  shasum -a 256 \
    "${standalone_fresh_home}/.config/systemd/user/vibeguard-gc.timer" \
    | awk '{print $1}'
)"
assert_cmd "fresh standalone install records exact systemd ownership" bash -c \
  'grep -qFx "phase=managed" "$3" \
    && grep -qFx "service_sha256=$1" "$3" \
    && grep -qFx "timer_sha256=$2" "$3"' _ \
  "${standalone_fresh_service_sha}" \
  "${standalone_fresh_timer_sha}" \
  "${standalone_fresh_receipt}"
: > "${standalone_fresh_log}"
assert_cmd "documented systemd installer preserves valid-owned refresh behavior" \
  env HOME="${standalone_fresh_home}" \
  PATH="${standalone_systemd_bin}:${PATH}" \
  VIBEGUARD_TEST_SYSTEMCTL_LOG="${standalone_fresh_log}" \
  bash "${REPO_DIR}/scripts/install-systemd.sh"
assert_cmd "valid-owned standalone refresh still invokes systemd" \
  test -s "${standalone_fresh_log}"

source "${REPO_DIR}/tests/setup/systemd_refresh_transaction_tests.sh"

standalone_malformed_home="${TMP_HOME}/standalone-systemd-malformed-home"
standalone_malformed_dir="${standalone_malformed_home}/.config/systemd/user"
standalone_malformed_receipt="${standalone_malformed_home}/.vibeguard/scheduler-ownership"
standalone_malformed_loaded="${standalone_malformed_home}/.systemctl-vibeguard-gc-active"
standalone_malformed_log="${TMP_HOME}/standalone-systemd-malformed-systemctl.log"
mkdir -p "${standalone_malformed_dir}" "$(dirname "${standalone_malformed_receipt}")"
printf 'custom service\n' > "${standalone_malformed_dir}/vibeguard-gc.service"
printf 'custom timer\n' > "${standalone_malformed_dir}/vibeguard-gc.timer"
printf 'schema=1\nkind=systemd\nphase=managed\nservice_sha256=invalid\ntimer_sha256=invalid\n' \
  > "${standalone_malformed_receipt}"
touch "${standalone_malformed_loaded}"
: > "${standalone_malformed_log}"
standalone_malformed_before="$(
  shasum -a 256 \
    "${standalone_malformed_dir}/vibeguard-gc.service" \
    "${standalone_malformed_dir}/vibeguard-gc.timer" \
    "${standalone_malformed_receipt}" "${standalone_malformed_loaded}"
)"
set +e
standalone_malformed_out="$(
  HOME="${standalone_malformed_home}" \
    PATH="${standalone_systemd_bin}:${PATH}" \
    VIBEGUARD_TEST_SYSTEMCTL_LOG="${standalone_malformed_log}" \
    bash "${REPO_DIR}/scripts/install-systemd.sh" 2>&1
)"
standalone_malformed_rc=$?
set -e
assert_cmd "standalone systemd install rejects a malformed ownership receipt" \
  test "${standalone_malformed_rc}" -ne 0
assert_contains "${standalone_malformed_out}" \
  "scheduler ownership receipt is invalid" \
  "standalone malformed receipt failure is explicit"
assert_cmd "malformed receipt preserves units, receipt, and loaded state" bash -c \
  'test "$(shasum -a 256 "$1" "$2" "$3" "$4")" = "$5"' _ \
  "${standalone_malformed_dir}/vibeguard-gc.service" \
  "${standalone_malformed_dir}/vibeguard-gc.timer" \
  "${standalone_malformed_receipt}" "${standalone_malformed_loaded}" \
  "${standalone_malformed_before}"
assert_cmd "malformed receipt performs no systemctl mutation" \
  test ! -s "${standalone_malformed_log}"

standalone_drift_home="${TMP_HOME}/standalone-systemd-drift-home"
standalone_drift_dir="${standalone_drift_home}/.config/systemd/user"
standalone_drift_receipt="${standalone_drift_home}/.vibeguard/scheduler-ownership"
standalone_drift_loaded="${standalone_drift_home}/.systemctl-vibeguard-gc-active"
standalone_drift_log="${TMP_HOME}/standalone-systemd-drift-systemctl.log"
mkdir -p "${standalone_drift_dir}" "$(dirname "${standalone_drift_receipt}")"
printf 'owned service\n' > "${standalone_drift_dir}/vibeguard-gc.service"
printf 'owned timer\n' > "${standalone_drift_dir}/vibeguard-gc.timer"
printf 'schema=1\nkind=systemd\nphase=managed\nservice_sha256=%s\ntimer_sha256=%s\n' \
  "$(shasum -a 256 "${standalone_drift_dir}/vibeguard-gc.service" | awk '{print $1}')" \
  "$(shasum -a 256 "${standalone_drift_dir}/vibeguard-gc.timer" | awk '{print $1}')" \
  > "${standalone_drift_receipt}"
printf 'local drift\n' >> "${standalone_drift_dir}/vibeguard-gc.service"
touch "${standalone_drift_loaded}"
: > "${standalone_drift_log}"
standalone_drift_before="$(
  shasum -a 256 \
    "${standalone_drift_dir}/vibeguard-gc.service" \
    "${standalone_drift_dir}/vibeguard-gc.timer" \
    "${standalone_drift_receipt}" "${standalone_drift_loaded}"
)"
set +e
standalone_drift_out="$(
  HOME="${standalone_drift_home}" \
    PATH="${standalone_systemd_bin}:${PATH}" \
    VIBEGUARD_TEST_SYSTEMCTL_LOG="${standalone_drift_log}" \
    bash "${REPO_DIR}/scripts/install-systemd.sh" 2>&1
)"
standalone_drift_rc=$?
set -e
assert_cmd "standalone systemd install rejects unit hash drift" \
  test "${standalone_drift_rc}" -ne 0
assert_contains "${standalone_drift_out}" \
  "scheduler ownership receipt does not match current systemd files" \
  "standalone unit hash drift failure is explicit"
assert_cmd "unit hash drift preserves units, receipt, and loaded state" bash -c \
  'test "$(shasum -a 256 "$1" "$2" "$3" "$4")" = "$5"' _ \
  "${standalone_drift_dir}/vibeguard-gc.service" \
  "${standalone_drift_dir}/vibeguard-gc.timer" \
  "${standalone_drift_receipt}" "${standalone_drift_loaded}" \
  "${standalone_drift_before}"
assert_cmd "unit hash drift performs no systemctl mutation" \
  test ! -s "${standalone_drift_log}"

systemd_remove_home="${TMP_HOME}/systemd-remove-receipt-home"
systemd_remove_dir="${systemd_remove_home}/.config/systemd/user"
systemd_remove_bin="${TMP_HOME}/systemd-remove-receipt-bin"
systemd_remove_receipt="${systemd_remove_home}/.vibeguard/scheduler-ownership"
mkdir -p "${systemd_remove_dir}" "${systemd_remove_bin}" "$(dirname "${systemd_remove_receipt}")"
sed "s|__VIBEGUARD_DIR__|${REPO_DIR}|g" \
  "${REPO_DIR}/scripts/systemd/vibeguard-gc.service" \
  > "${systemd_remove_dir}/vibeguard-gc.service"
cp "${REPO_DIR}/scripts/systemd/vibeguard-gc.timer" \
  "${systemd_remove_dir}/vibeguard-gc.timer"
printf 'schema=1\nkind=systemd\nphase=managed\nservice_sha256=%s\ntimer_sha256=%s\n' \
  "$(shasum -a 256 "${systemd_remove_dir}/vibeguard-gc.service" | awk '{print $1}')" \
  "$(shasum -a 256 "${systemd_remove_dir}/vibeguard-gc.timer" | awk '{print $1}')" \
  > "${systemd_remove_receipt}"
cat > "${systemd_remove_bin}/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Linux
SH
cat > "${systemd_remove_bin}/systemctl" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "--user" ]] && shift
case "${VIBEGUARD_TEST_SYSTEMD_REMOVE_MODE:-success}:${1:-}" in
  service-active:stop)
    [[ "${2:-}" == "vibeguard-gc.service" ]] && exit 9
    exit 0
    ;;
  service-active:is-active)
    if [[ "${2:-}" == "vibeguard-gc.service" ]]; then
      printf 'active\n'
      exit 0
    fi
    printf 'inactive\n'
    exit 3
    ;;
  service-active:*)
    exit 0
    ;;
  success:stop|success:disable|success:daemon-reload) exit 0 ;;
  success:is-active) printf 'inactive\n'; exit 3 ;;
  success:is-enabled) printf 'disabled\n'; exit 1 ;;
  active:stop) exit 9 ;;
  active:is-active) printf 'active\n'; exit 0 ;;
  active:*) exit 0 ;;
  absent:stop|absent:disable) exit 5 ;;
  absent:is-active) printf 'unknown\n'; exit 4 ;;
  absent:is-enabled) printf 'not-found\n'; exit 4 ;;
  absent:daemon-reload) exit 0 ;;
  reload-failure:stop|reload-failure:disable) exit 0 ;;
  reload-failure:is-active) printf 'inactive\n'; exit 3 ;;
  reload-failure:is-enabled) printf 'disabled\n'; exit 1 ;;
  reload-failure:daemon-reload) exit 9 ;;
  *) exit 64 ;;
esac
SH
chmod +x "${systemd_remove_bin}/uname" "${systemd_remove_bin}/systemctl"
assert_cmd "documented systemd remover clears matching units and ownership receipt" \
  env HOME="${systemd_remove_home}" PATH="${systemd_remove_bin}:${PATH}" \
  bash "${REPO_DIR}/scripts/install-systemd.sh" --remove
assert_cmd "systemd remover leaves no stale scheduler ownership state" bash -c \
  'test ! -e "$1" && test ! -e "$2" && test ! -e "$3"' _ \
  "${systemd_remove_dir}/vibeguard-gc.service" \
  "${systemd_remove_dir}/vibeguard-gc.timer" "${systemd_remove_receipt}"

systemd_remove_failure_home="${TMP_HOME}/systemd-remove-failure-home"
systemd_remove_failure_dir="${systemd_remove_failure_home}/.config/systemd/user"
systemd_remove_failure_receipt="${systemd_remove_failure_home}/.vibeguard/scheduler-ownership"
mkdir -p "${systemd_remove_failure_dir}" "$(dirname "${systemd_remove_failure_receipt}")"
printf '[Service]\n' > "${systemd_remove_failure_dir}/vibeguard-gc.service"
printf '[Timer]\n' > "${systemd_remove_failure_dir}/vibeguard-gc.timer"
printf 'schema=1\nkind=systemd\nphase=managed\nservice_sha256=%s\ntimer_sha256=%s\n' \
  "$(shasum -a 256 "${systemd_remove_failure_dir}/vibeguard-gc.service" | awk '{print $1}')" \
  "$(shasum -a 256 "${systemd_remove_failure_dir}/vibeguard-gc.timer" | awk '{print $1}')" \
  > "${systemd_remove_failure_receipt}"
systemd_remove_failure_rc=0
HOME="${systemd_remove_failure_home}" PATH="${systemd_remove_bin}:${PATH}" \
  VIBEGUARD_TEST_SYSTEMD_REMOVE_MODE=active \
  bash "${REPO_DIR}/scripts/install-systemd.sh" --remove >/dev/null 2>&1 \
  || systemd_remove_failure_rc=$?
assert_cmd "systemd remover fails when inactivity is not proven" \
  test "${systemd_remove_failure_rc}" -ne 0
assert_cmd "failed systemd deactivation preserves units and ownership receipt" bash -c \
  'test -f "$1" && test -f "$2" && test -f "$3"' _ \
  "${systemd_remove_failure_dir}/vibeguard-gc.service" \
  "${systemd_remove_failure_dir}/vibeguard-gc.timer" \
  "${systemd_remove_failure_receipt}"

systemd_service_failure_home="${TMP_HOME}/systemd-service-failure-home"
systemd_service_failure_dir="${systemd_service_failure_home}/.config/systemd/user"
systemd_service_failure_receipt="${systemd_service_failure_home}/.vibeguard/scheduler-ownership"
mkdir -p "${systemd_service_failure_dir}" \
  "$(dirname "${systemd_service_failure_receipt}")"
printf '[Service]\n' > "${systemd_service_failure_dir}/vibeguard-gc.service"
printf '[Timer]\n' > "${systemd_service_failure_dir}/vibeguard-gc.timer"
printf 'schema=1\nkind=systemd\nphase=managed\nservice_sha256=%s\ntimer_sha256=%s\n' \
  "$(shasum -a 256 "${systemd_service_failure_dir}/vibeguard-gc.service" | awk '{print $1}')" \
  "$(shasum -a 256 "${systemd_service_failure_dir}/vibeguard-gc.timer" | awk '{print $1}')" \
  > "${systemd_service_failure_receipt}"
systemd_service_failure_rc=0
HOME="${systemd_service_failure_home}" PATH="${systemd_remove_bin}:${PATH}" \
  VIBEGUARD_TEST_SYSTEMD_REMOVE_MODE=service-active \
  bash "${REPO_DIR}/scripts/install-systemd.sh" --remove >/dev/null 2>&1 \
  || systemd_service_failure_rc=$?
assert_cmd "systemd remover fails when oneshot service inactivity is not proven" \
  test "${systemd_service_failure_rc}" -ne 0
assert_cmd "active service preserves standalone units and ownership receipt" bash -c \
  'test -f "$1" && test -f "$2" && test -f "$3"' _ \
  "${systemd_service_failure_dir}/vibeguard-gc.service" \
  "${systemd_service_failure_dir}/vibeguard-gc.timer" \
  "${systemd_service_failure_receipt}"

systemd_reload_failure_home="${TMP_HOME}/systemd-reload-failure-home"
systemd_reload_failure_dir="${systemd_reload_failure_home}/.config/systemd/user"
systemd_reload_failure_receipt="${systemd_reload_failure_home}/.vibeguard/scheduler-ownership"
mkdir -p "${systemd_reload_failure_dir}" "$(dirname "${systemd_reload_failure_receipt}")"
printf '[Service]\n' > "${systemd_reload_failure_dir}/vibeguard-gc.service"
printf '[Timer]\n' > "${systemd_reload_failure_dir}/vibeguard-gc.timer"
printf 'schema=1\nkind=systemd\nphase=managed\nservice_sha256=%s\ntimer_sha256=%s\n' \
  "$(shasum -a 256 "${systemd_reload_failure_dir}/vibeguard-gc.service" | awk '{print $1}')" \
  "$(shasum -a 256 "${systemd_reload_failure_dir}/vibeguard-gc.timer" | awk '{print $1}')" \
  > "${systemd_reload_failure_receipt}"
systemd_reload_failure_rc=0
HOME="${systemd_reload_failure_home}" PATH="${systemd_remove_bin}:${PATH}" \
  VIBEGUARD_TEST_SYSTEMD_REMOVE_MODE=reload-failure \
  bash "${REPO_DIR}/scripts/install-systemd.sh" --remove >/dev/null 2>&1 \
  || systemd_reload_failure_rc=$?
assert_cmd "systemd remover fails when daemon reload fails" \
  test "${systemd_reload_failure_rc}" -ne 0
assert_cmd "daemon reload failure restores units and preserves receipt" bash -c \
  'test -f "$1" && test -f "$2" && test -f "$3"' _ \
  "${systemd_reload_failure_dir}/vibeguard-gc.service" \
  "${systemd_reload_failure_dir}/vibeguard-gc.timer" \
  "${systemd_reload_failure_receipt}"

systemd_absent_retry_home="${TMP_HOME}/systemd-absent-retry-home"
systemd_absent_retry_receipt="${systemd_absent_retry_home}/.vibeguard/scheduler-ownership"
mkdir -p "$(dirname "${systemd_absent_retry_receipt}")"
printf 'schema=1\nkind=systemd\nphase=cleaning\nservice_sha256=%064d\ntimer_sha256=%064d\n' \
  0 0 > "${systemd_absent_retry_receipt}"
assert_cmd "setup clean accepts absent systemd unit errors after safe postconditions" \
  env HOME="${systemd_absent_retry_home}" PATH="${systemd_remove_bin}:${PATH}" \
  VIBEGUARD_TEST_SYSTEMD_REMOVE_MODE=absent VIBEGUARD_TEST_UNAME=Linux \
  bash "${REPO_DIR}/setup.sh" --clean
assert_cmd "absent-unit clean retry removes the cleaning receipt" \
  test ! -e "${systemd_absent_retry_receipt}"

assert_cmd "health report scheduled wrapper exists at canonical path" test -x "${REPO_DIR}/scripts/health-report-scheduled.sh"
assert_cmd "health report scheduler installer exists at canonical path" test -x "${REPO_DIR}/scripts/install-health-report-scheduler.sh"
assert_cmd "health report launchd plist points to canonical wrapper path" grep -q "__VIBEGUARD_DIR__/scripts/health-report-scheduled.sh" "${REPO_DIR}/scripts/setup/com.vibeguard.health-report.plist"

header "seed existing config"
mkdir -p "${HOME}/.claude" "${HOME}/.codex"
case "${HOME}" in
  "${TMP_HOME}"*) ;;
  *) red "refusing to write hook fixture outside TMP_HOME"; exit 1 ;;
esac
PREEXISTING_CODEX_HOOK_SCRIPT="${HOME}/codex-third-party-hook.js"
printf 'process.exit(0)\n' > "${PREEXISTING_CODEX_HOOK_SCRIPT}"
cat > "${HOME}/.claude/settings.json" <<'JSON'
{
  "hooks": {}
}
JSON
cat > "${HOME}/.codex/hooks.json" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node ${PREEXISTING_CODEX_HOOK_SCRIPT}"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${HOME}/.codex/config.toml" <<'TOML'
[features]
hooks = true
TOML
assert_cmd "Pre-existing non-VibeGuard Codex hook is present" grep -q "node ${PREEXISTING_CODEX_HOOK_SCRIPT}" "${HOME}/.codex/hooks.json"

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
invalid_project_dry_run_home="${TMP_HOME}/invalid-project-dry-run-home"
mkdir -p "${invalid_project_dry_run_home}"
set +e
invalid_project_dry_run_out="$(HOME="${invalid_project_dry_run_home}" VIBEGUARD_PROJECT_CONFIG="${bad_project_config}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --dry-run 2>&1)"
invalid_project_dry_run_rc=$?
set -e
assert_cmd "setup dry-run refuses invalid .vibeguard.json" test "${invalid_project_dry_run_rc}" -ne 0
assert_contains "${invalid_project_dry_run_out}" "vibeguard-runtime downloaded and verified" "setup dry-run prepares runtime before project config validation"
assert_contains "${invalid_project_dry_run_out}" "ERROR: invalid project config" "setup dry-run reports invalid .vibeguard.json"
assert_contains "${invalid_project_dry_run_out}" ".profile: unsupported value" "setup dry-run reports invalid project profile"
assert_not_contains "${invalid_project_dry_run_out}" "Dry run complete" "setup dry-run with invalid project config does not report complete"
assert_cmd "invalid setup dry-run does not write repo-path" test ! -e "${invalid_project_dry_run_home}/.vibeguard/repo-path"
assert_cmd "invalid setup dry-run does not write runtime config" test ! -e "${invalid_project_dry_run_home}/.vibeguard/config.json"
invalid_project_install_home="${TMP_HOME}/invalid-project-install-home"
mkdir -p "${invalid_project_install_home}"
set +e
invalid_project_install_out="$(HOME="${invalid_project_install_home}" VIBEGUARD_PROJECT_CONFIG="${bad_project_config}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes 2>&1)"
invalid_project_install_rc=$?
set -e
assert_cmd "setup install refuses invalid .vibeguard.json" test "${invalid_project_install_rc}" -ne 0
assert_contains "${invalid_project_install_out}" "vibeguard-runtime downloaded and verified" "setup install prepares runtime before project config validation"
assert_contains "${invalid_project_install_out}" "ERROR: invalid project config" "setup install reports invalid .vibeguard.json"
assert_contains "${invalid_project_install_out}" ".profile: unsupported value" "setup install reports invalid project profile"
assert_not_contains "${invalid_project_install_out}" "Setup complete! All components installed." "setup install with invalid project config does not report complete"
assert_cmd "invalid setup install does not write repo-path" test ! -e "${invalid_project_install_home}/.vibeguard/repo-path"
assert_cmd "invalid setup install does not write run-hook wrapper" test ! -e "${invalid_project_install_home}/.vibeguard/run-hook.sh"
assert_cmd "invalid setup install does not write Codex run-hook wrapper" test ! -e "${invalid_project_install_home}/.vibeguard/run-hook-codex.sh"
assert_cmd "invalid setup install does not seed runtime config" test ! -e "${invalid_project_install_home}/.vibeguard/config.json"
assert_cmd "invalid setup install does not install snapshot" test ! -e "${invalid_project_install_home}/.vibeguard/installed"

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
assert_cmd "--dry-run does not install health report launchd scheduler" test ! -e "${HOME}/Library/LaunchAgents/com.vibeguard.health-report.plist"

valid_project_config="${TMP_HOME}/valid-vibeguard.json"
cat > "${valid_project_config}" <<'JSON'
{
  "profile": "core",
  "gc": {
    "log_threshold_mb": 7
  }
}
JSON
valid_project_install_home="${TMP_HOME}/valid-project-install-home"
mkdir -p "${valid_project_install_home}"
valid_project_install_out="$(HOME="${valid_project_install_home}" VIBEGUARD_PROJECT_CONFIG="${valid_project_config}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes 2>&1)" || { printf '%s\n' "${valid_project_install_out}" >&2; exit 1; }
assert_contains "${valid_project_install_out}" "vibeguard-runtime downloaded and verified" "setup install prepares runtime for valid project config"
assert_contains "${valid_project_install_out}" "Project config valid: ${valid_project_config}" "setup install validates project config with prepared runtime"
assert_contains "${valid_project_install_out}" "Setup complete! All components installed." "clean setup install with project config succeeds"

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

manifest_fail_home="${TMP_HOME}/manifest-fail-home"
mkdir -p "${manifest_fail_home}"
set +e
manifest_fail_out="$(HOME="${manifest_fail_home}" VIBEGUARD_TEST_BAD_MANIFEST=1 VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes 2>&1)"
manifest_fail_rc=$?
set -e
assert_cmd "tampered runtime release manifest exits nonzero" test "${manifest_fail_rc}" -ne 0
assert_contains "${manifest_fail_out}" "runtime release manifest checksum mismatch" "tampered runtime release manifest reports checksum mismatch"
assert_not_contains "${manifest_fail_out}" "Falling back to source build" "tampered runtime release manifest does not fall back to source"
assert_not_contains "${manifest_fail_out}" "Setup complete! All components installed." "tampered runtime release manifest does not report setup complete"

manifest_size_fail_home="${TMP_HOME}/manifest-size-fail-home"
mkdir -p "${manifest_size_fail_home}"
set +e
manifest_size_fail_out="$(HOME="${manifest_size_fail_home}" VIBEGUARD_TEST_BAD_MANIFEST_SIZE=1 VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes 2>&1)"
manifest_size_fail_rc=$?
set -e
assert_cmd "tampered runtime release manifest size exits nonzero" test "${manifest_size_fail_rc}" -ne 0
assert_contains "${manifest_size_fail_out}" "runtime release manifest size mismatch" "tampered runtime release manifest reports size mismatch"
assert_not_contains "${manifest_size_fail_out}" "Falling back to source build" "tampered runtime release manifest size does not fall back to source"
assert_not_contains "${manifest_size_fail_out}" "Setup complete! All components installed." "tampered runtime release manifest size does not report setup complete"

require_provenance_fail_home="${TMP_HOME}/require-provenance-fail-home"
mkdir -p "${require_provenance_fail_home}"
set +e
require_provenance_fail_out="$(HOME="${require_provenance_fail_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes --require-provenance 2>&1)"
require_provenance_fail_rc=$?
set -e
assert_cmd "--require-provenance exits nonzero when attestation verifier is unavailable" test "${require_provenance_fail_rc}" -ne 0
assert_contains "${require_provenance_fail_out}" "Mode: require-provenance" "--require-provenance reports strict mode"
assert_contains "${require_provenance_fail_out}" "provenance verification is required but unavailable" "--require-provenance fails closed on checksum-only provenance"
assert_contains "${require_provenance_fail_out}" "gh attestation verify unavailable" "--require-provenance reports missing attestation verifier"
assert_not_contains "${require_provenance_fail_out}" "Setup complete! All components installed." "--require-provenance unavailable verifier does not report setup complete"

require_provenance_ok_home="${TMP_HOME}/require-provenance-ok-home"
mkdir -p "${require_provenance_ok_home}"
require_provenance_ok_out="$(HOME="${require_provenance_ok_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 VIBEGUARD_TEST_ATTESTATION_AVAILABLE=1 VIBEGUARD_TEST_GH_AUTH_OK=1 VIBEGUARD_TEST_ATTESTATION_OK=1 bash "${REPO_DIR}/setup.sh" --yes --require-provenance)"
assert_contains "${require_provenance_ok_out}" "Mode: require-provenance" "--require-provenance success reports strict mode"
assert_contains "${require_provenance_ok_out}" "provenance=verified-provenance" "--require-provenance requires verified provenance"
assert_contains "${require_provenance_ok_out}" "runtime provenance status: verified-provenance" "--require-provenance records verified provenance status"
assert_contains "${require_provenance_ok_out}" "Setup complete! All components installed." "--require-provenance install succeeds with verified attestation"

require_provenance_mismatch_home="${TMP_HOME}/require-provenance-mismatch-home"
mkdir -p "${require_provenance_mismatch_home}"
set +e
require_provenance_mismatch_out="$(HOME="${require_provenance_mismatch_home}" VIBEGUARD_TEST_RUNTIME_VERSION=0.0.0 VIBEGUARD_TEST_ATTESTATION_AVAILABLE=1 VIBEGUARD_TEST_GH_AUTH_OK=1 VIBEGUARD_TEST_ATTESTATION_OK=1 bash "${REPO_DIR}/setup.sh" --yes --require-provenance 2>&1)"
require_provenance_mismatch_rc=$?
set -e
assert_cmd "--require-provenance exits nonzero when verified runtime version mismatches" test "${require_provenance_mismatch_rc}" -ne 0
assert_contains "${require_provenance_mismatch_out}" "prepared vibeguard-runtime is incompatible" "--require-provenance mismatch reports incompatible runtime"
assert_contains "${require_provenance_mismatch_out}" "--require-provenance requires a downloaded runtime that matches the repo runtime VERSION" "--require-provenance mismatch fails before source fallback"
assert_not_contains "${require_provenance_mismatch_out}" "Falling back to source build" "--require-provenance mismatch does not fall back to source"
assert_not_contains "${require_provenance_mismatch_out}" "Setup complete! All components installed." "--require-provenance mismatch does not report setup complete"

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
assert_cmd "--runtime-version tries runtime release manifest download" grep -qF "vibeguard-runtime-releases.json" "${version_override_log}"

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

no_python_home="${TMP_HOME}/no-python-install-home"
no_python_bin="${TMP_HOME}/no-python-bin"
mkdir -p "${no_python_home}" "${no_python_bin}"
cat > "${no_python_bin}/python3" <<'SH'
#!/usr/bin/env bash
printf 'python3 unexpectedly executed: %s\n' "$*" >&2
exit 127
SH
chmod +x "${no_python_bin}/python3"
ln -sf "${no_python_bin}/python3" "${no_python_bin}/python"
no_python_path="${no_python_bin}:${PATH}"
no_python_install_out="$(HOME="${no_python_home}" PATH="${no_python_path}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes --profile core 2>&1)"
assert_contains "${no_python_install_out}" "Setup complete! All components installed." "no-Python setup install succeeds"
assert_contains "${no_python_install_out}" "vibeguard-runtime downloaded and verified" "no-Python setup uses verified prebuilt runtime"
assert_not_contains "${no_python_install_out}" "python3 unexpectedly executed" "no-Python setup install does not execute python3"

fresh_no_python_home="${TMP_HOME}/fresh-no-python-home"
mkdir -p "${fresh_no_python_home}"
set +e
fresh_no_python_check_out="$(HOME="${fresh_no_python_home}" PATH="${no_python_path}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 VIBEGUARD_SETUP_SKIP_REPO_RUNTIME=1 bash "${REPO_DIR}/setup.sh" --check --strict 2>&1)"
fresh_no_python_check_rc=$?
set -e
assert_cmd "fresh no-Python setup --check --strict exits broken but runs" test "${fresh_no_python_check_rc}" -eq 2
assert_contains "${fresh_no_python_check_out}" "VibeGuard Installation Status" "fresh no-Python setup --check emits status"
assert_not_contains "${fresh_no_python_check_out}" "python3 unexpectedly executed" "fresh no-Python setup --check does not execute python3"
fresh_no_python_clean_out="$(HOME="${fresh_no_python_home}" PATH="${no_python_path}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 VIBEGUARD_SETUP_SKIP_REPO_RUNTIME=1 bash "${REPO_DIR}/setup.sh" --clean 2>&1)"
assert_contains "${fresh_no_python_clean_out}" "VibeGuard cleaned." "fresh no-Python setup --clean succeeds without installed runtime"
assert_not_contains "${fresh_no_python_clean_out}" "python3 unexpectedly executed" "fresh no-Python setup --clean does not execute python3"

set +e
no_python_check_out="$(HOME="${no_python_home}" PATH="${no_python_path}" bash "${REPO_DIR}/setup.sh" --check --strict 2>&1)"
no_python_check_rc=$?
set -e
assert_cmd "no-Python setup --check --strict exits 0" test "${no_python_check_rc}" -eq 0
assert_not_contains "${no_python_check_out}" "python3 unexpectedly executed" "no-Python setup --check does not execute python3"
no_python_clean_out="$(HOME="${no_python_home}" PATH="${no_python_path}" bash "${REPO_DIR}/setup.sh" --clean 2>&1)"
assert_contains "${no_python_clean_out}" "VibeGuard cleaned." "no-Python setup --clean succeeds"
assert_not_contains "${no_python_clean_out}" "python3 unexpectedly executed" "no-Python setup --clean does not execute python3"
assert_cmd "no-Python setup --clean removes install state" test ! -e "${no_python_home}/.vibeguard/install-state.json"

install_out="$(VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" bash "${REPO_DIR}/setup.sh" --yes)"
assert_contains "${install_out}" "Setup complete! All components installed." "Default route to installation process"
assert_contains "${install_out}" "Mode: installed snapshot (execution uses ~/.vibeguard/installed)" "default setup reports installed snapshot mode"
assert_contains "${install_out}" "vibeguard-runtime downloaded and verified" "default setup uses verified prebuilt runtime without cargo"
assert_contains "${install_out}" "Scheduled GC not installed by default" "default setup reports scheduled GC opt-in"
assert_cmd "default setup does not install scheduled GC" assert_scheduled_gc_absent
assert_cmd "default setup writes installed snapshot execution mode" grep -q '^installed-snapshot$' "${HOME}/.vibeguard/execution-mode"
assert_cmd "default Claude rules point to durable installed routing contract" grep -qF "${HOME}/.vibeguard/installed/workflows/references/routing-contract.md" "${HOME}/.claude/CLAUDE.md"
assert_cmd "default Codex rules point to durable installed routing contract" grep -qF "${HOME}/.vibeguard/installed/workflows/references/routing-contract.md" "${HOME}/.codex/AGENTS.md"
assert_cmd "default host rules do not point to source checkout" bash -c "! grep -qF '${REPO_DIR}/workflows/references/routing-contract.md' '${HOME}/.claude/CLAUDE.md' '${HOME}/.codex/AGENTS.md'"
assert_contains "${install_out}" "Removed retired VibeGuard skill link" "setup install removes tracked retired skill links"
assert_cmd "setup install removes tracked retired Claude skill" test ! -L "${HOME}/.claude/skills/old-retired"
assert_cmd "setup install removes tracked retired Codex skill" test ! -L "${HOME}/.codex/skills/old-flow"
assert_cmd "vg shortcut commands are installed after setup" test -L "${HOME}/.claude/commands/vg"
assert_cmd "vibeguard-runtime binary installed after setup" test -x "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
assert_cmd "vibeguard command installed after setup" test -x "${HOME}/.vibeguard/installed/bin/vibeguard"
assert_cmd "vibeguard command targets the installed runtime" bash -c '
  [[ "$(readlink "$1")" == "vibeguard-runtime" ]]
' _ "${HOME}/.vibeguard/installed/bin/vibeguard"
assert_cmd "vibeguard-runtime version matches VERSION after setup" bash -c '
  runtime="$1"
  version_file="$2"
  [[ "$("${runtime}" version)" == "$(tr -d "[:space:]" < "${version_file}")" ]]
' _ "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" "${REPO_DIR}/vibeguard-runtime/VERSION"
assert_cmd "runtime policy project schema installed after setup" test -f "${HOME}/.vibeguard/installed/schemas/vibeguard-project.schema.json"
assert_cmd "runtime config schema installed after setup" test -f "${HOME}/.vibeguard/installed/schemas/vibeguard-runtime-config.schema.json"
printf '{"profile":"core"}\n' > "${TMP_HOME}/valid-project-config.json"
assert_cmd "runtime policy project validator moved into runtime" "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" project-config-validate "${TMP_HOME}/valid-project-config.json"
assert_cmd "runtime policy Python project validator not installed after setup" test ! -e "${HOME}/.vibeguard/installed/scripts/lib/project_config_validate.py"
assert_contains "${install_out}" "[OK] vibeguard-runtime version matches repo VERSION" "setup install reports runtime version health"
assert_contains "${install_out}" "[OK] Installed hooks+guards snapshot matches repo-path HEAD" "setup install reports current installed snapshot"
assert_contains "${install_out}" "~/.vibeguard/config.json present (preserved)" "setup preserves seeded runtime config during install"
assert_cmd "pre-push wrapper is installed after setup" test -x "${HOME}/.vibeguard/pre-push"
assert_cmd "repo pre-commit hook is installed after setup" assert_repo_git_hook_target "pre-commit" "${HOME}/.vibeguard/pre-commit"
assert_cmd "repo pre-push hook is installed after setup" assert_repo_git_hook_target "pre-push" "${HOME}/.vibeguard/pre-push"
assert_cmd "Claude eval-harness skill targets installed snapshot" bash -c "[[ \"\$(readlink '${HOME}/.claude/skills/eval-harness')\" == '${HOME}/.vibeguard/installed/skills/eval-harness' ]]"
assert_cmd "Claude command target uses installed snapshot" bash -c "[[ \"\$(readlink '${HOME}/.claude/commands/vg')\" == '${HOME}/.vibeguard/installed/.claude/commands/vg' ]]"
assert_cmd "core profile does not front-inject the native rule tree (GH-541)" test ! -e "${HOME}/.claude/rules/vibeguard/common/security.md"
fake_live_repo="${TMP_HOME}/fake-live-repo"
mkdir -p "${fake_live_repo}/hooks/git" "${fake_live_repo}/hooks"
cat > "${fake_live_repo}/hooks/git/pre-push" <<'SH'
#!/usr/bin/env bash
printf 'fake live repo pre-push executed\n' >&2
exit 47
SH
cat > "${fake_live_repo}/hooks/pre-commit-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'fake live repo pre-commit executed\n' >&2
exit 48
SH
chmod +x "${fake_live_repo}/hooks/git/pre-push" "${fake_live_repo}/hooks/pre-commit-guard.sh"
printf '%s' "${fake_live_repo}" > "${HOME}/.vibeguard/repo-path"
set +e
stable_pre_push_out="$(bash "${HOME}/.vibeguard/pre-push" </dev/null 2>&1)"
stable_pre_push_rc=$?
stable_pre_commit_out="$(cd "${TMP_HOME}" && bash "${HOME}/.vibeguard/pre-commit" 2>&1)"
stable_pre_commit_rc=$?
set -e
assert_cmd "stable pre-push ignores live repo-path" test "${stable_pre_push_rc}" -eq 0
assert_not_contains "${stable_pre_push_out}" "fake live repo pre-push executed" "stable pre-push does not execute live repo script"
assert_cmd "stable pre-commit ignores live repo-path" test "${stable_pre_commit_rc}" -eq 0
assert_not_contains "${stable_pre_commit_out}" "fake live repo pre-commit executed" "stable pre-commit does not execute live repo script"
printf '%s' "${REPO_DIR}" > "${HOME}/.vibeguard/repo-path"
default_scheduler_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${default_scheduler_check_out}" "[INFO] Scheduled GC not installed (optional, opt in: bash setup.sh --yes --with-scheduler)" "--check reports absent scheduled GC as INFO"
assert_contains "${default_scheduler_check_out}" "[OK] vibeguard-runtime version matches repo VERSION" "--check reports runtime version health"
assert_contains "${default_scheduler_check_out}" "[OK] Execution mode: installed snapshot" "--check reports installed snapshot execution mode"
assert_contains "${default_scheduler_check_out}" "Hook wrapper execution source: installed snapshot" "--check reports hook wrapper execution source"
assert_contains "${default_scheduler_check_out}" "Git pre-push execution source: installed snapshot" "--check reports git pre-push execution source"
assert_contains "${default_scheduler_check_out}" "Native rules execution source: installed snapshot" "--check reports native rules execution source"
assert_contains "${default_scheduler_check_out}" "Claude commands execution source: installed snapshot" "--check reports Claude commands execution source"
assert_contains "${default_scheduler_check_out}" "Runtime execution source: installed snapshot" "--check reports runtime execution source"
assert_not_contains "${default_scheduler_check_out}" "[WARN] Scheduled GC" "--check does not warn when scheduled GC is absent"

dev_linked_home="${TMP_HOME}/dev-linked-home"
mkdir -p "${dev_linked_home}"
# GH-541: the native rule tree is only front-injected under full/strict, so use
# the full profile here to exercise dev-linked rule-symlink target resolution.
dev_linked_out="$(HOME="${dev_linked_home}" VIBEGUARD_TEST_CARGO_UNAVAILABLE=1 bash "${REPO_DIR}/setup.sh" --yes --dev-linked --profile full)"
assert_contains "${dev_linked_out}" "Mode: dev-linked repo (execution uses live repository paths)" "--dev-linked mode is visible during setup"
assert_cmd "--dev-linked writes explicit execution mode" grep -q '^dev-linked-repo$' "${dev_linked_home}/.vibeguard/execution-mode"
assert_cmd "--dev-linked Claude skill targets repo" bash -c "[[ \"\$(readlink '${dev_linked_home}/.claude/skills/eval-harness')\" == '${REPO_DIR}/skills/eval-harness' ]]"
assert_cmd "--dev-linked native rule targets repo" bash -c "[[ \"\$(readlink '${dev_linked_home}/.claude/rules/vibeguard/common/security.md')\" == '${REPO_DIR}/rules/claude-rules/common/security.md' ]]"
assert_cmd "--dev-linked host rules point to live routing contract" grep -qF "${REPO_DIR}/workflows/references/routing-contract.md" "${dev_linked_home}/.claude/CLAUDE.md" "${dev_linked_home}/.codex/AGENTS.md"
dev_linked_check_out="$(HOME="${dev_linked_home}" bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${dev_linked_check_out}" "[INFO] Execution mode: dev-linked repo (explicit opt-in)" "--check visibly marks dev-linked mode"
assert_contains "${dev_linked_check_out}" "Hook wrapper execution source: dev-linked repo" "--check reports dev-linked hook source"
dev_fake_repo="${TMP_HOME}/dev-linked-fake-repo"
mkdir -p "${dev_fake_repo}/hooks/git" "${dev_fake_repo}/hooks"
cat > "${dev_fake_repo}/hooks/git/pre-push" <<'SH'
#!/usr/bin/env bash
printf 'dev linked fake pre-push executed\n' >&2
exit 47
SH
chmod +x "${dev_fake_repo}/hooks/git/pre-push"
printf '%s' "${dev_fake_repo}" > "${dev_linked_home}/.vibeguard/repo-path"
set +e
dev_linked_pre_push_out="$(HOME="${dev_linked_home}" bash "${dev_linked_home}/.vibeguard/pre-push" </dev/null 2>&1)"
dev_linked_pre_push_rc=$?
set -e
assert_cmd "--dev-linked pre-push executes live repo source" test "${dev_linked_pre_push_rc}" -eq 47
assert_contains "${dev_linked_pre_push_out}" "dev linked fake pre-push executed" "--dev-linked pre-push proves live repo execution is opt-in"
