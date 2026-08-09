# --- Codex hook timeout diagnostics ---
header "codex hook timeout diagnostics"
TIMEOUT_HOOK_HOME="$(mktemp -d)"
mkdir -p "${TIMEOUT_HOOK_HOME}/.codex" "${TIMEOUT_HOOK_HOME}/.vibeguard/installed/hooks"
cp "${REPO_DIR}/hooks/run-hook-codex.sh" "${TIMEOUT_HOOK_HOME}/.vibeguard/run-hook-codex.sh"
cat > "${TIMEOUT_HOOK_HOME}/.codex/hooks.json" <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node /tmp/orca/codex-bridge.js"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node /tmp/orca/stop-bridge.js"
          }
        ]
      }
    ]
  }
}
JSON

timeout_helper_out="$(HOME="${TIMEOUT_HOOK_HOME}" python3 "${REPO_DIR}/scripts/lib/codex_hooks_json.py" check-timeouts --hooks-file "${TIMEOUT_HOOK_HOME}/.codex/hooks.json" 2>&1 || true)"
assert_contains "$timeout_helper_out" "unmanaged Codex hook without timeout" "timeout helper: reports unmanaged hook"
assert_contains "$timeout_helper_out" "event=PostToolUse matcher=Bash" "timeout helper: reports event and matcher"
assert_contains "$timeout_helper_out" "command=node /tmp/orca/codex-bridge.js" "timeout helper: reports Orca bridge command"
assert_contains "$timeout_helper_out" "event=Stop matcher=<none>" "timeout helper: reports unmanaged Stop hook"
assert_contains "$timeout_helper_out" "command=node /tmp/orca/stop-bridge.js" "timeout helper: reports Stop bridge command"
assert_contains "$timeout_helper_out" "repair=add timeout or consult hook owner" "timeout helper: reports repair direction"

timeout_check_out="$(HOME="${TIMEOUT_HOOK_HOME}" bash "${SETUP_SCRIPT}" --check 2>&1 || true)"
assert_contains "$timeout_check_out" "[WARN] unmanaged Codex hook without timeout" "setup --check: surfaces unmanaged hook without timeout"

# --- Payload systemd target validation ---
header "payload systemd scheduler target validation"
SYSTEMD_CHECK_HOME="$(mktemp -d)"
systemd_check_bin="${SYSTEMD_CHECK_HOME}/bin"
systemd_check_service="${SYSTEMD_CHECK_HOME}/.config/systemd/user/vibeguard-gc.service"
systemd_check_timer="${SYSTEMD_CHECK_HOME}/.config/systemd/user/vibeguard-gc.timer"
systemd_check_version_root="${SYSTEMD_CHECK_HOME}/.vibeguard/dist/1.2.3"
systemd_check_expected="${SYSTEMD_CHECK_HOME}/.vibeguard/dist/current/scripts/gc/gc-scheduled.sh"
mkdir -p "${systemd_check_bin}" "$(dirname "${systemd_check_service}")" \
  "${systemd_check_version_root}/scripts/gc"
ln -s "1.2.3" "${SYSTEMD_CHECK_HOME}/.vibeguard/dist/current"
printf '#!/usr/bin/env bash\nexit 0\n' > "${systemd_check_expected}"
chmod +x "${systemd_check_expected}"
printf '%s\n' '[Timer]' 'Unit=vibeguard-gc.service' > "${systemd_check_timer}"
cat > "${systemd_check_bin}/uname" <<'SH'
#!/usr/bin/env bash
printf 'Linux\n'
SH
cat > "${systemd_check_bin}/systemctl" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "--user" ]] && shift
case "${1:-}" in
  is-active) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "${systemd_check_bin}/uname" "${systemd_check_bin}/systemctl"
systemd_check_run() {
  env HOME="${SYSTEMD_CHECK_HOME}" \
    PATH="${systemd_check_bin}:${PATH}" \
    VIBEGUARD_PAYLOAD_MODE=1 \
    VIBEGUARD_REPO_DIR="${REPO_DIR}" \
    bash "${CHECK_SCRIPT}" "$@"
}
printf '%s\n' '[Service]' \
  "ExecStart=/bin/bash \"${systemd_check_expected}\"" \
  > "${systemd_check_service}"
systemd_stable_out="$(systemd_check_run 2>&1 || true)"
assert_contains "${systemd_stable_out}" "[OK] Scheduled GC active via systemd" \
  "payload doctor accepts exact stable systemd target"

rm -f "${systemd_check_timer}"
systemd_missing_timer_out="$(systemd_check_run 2>&1 || true)"
assert_contains "${systemd_missing_timer_out}" \
  "[BROKEN] Scheduled GC systemd timer missing or not a regular file:" \
  "payload doctor rejects an active timer missing its on-disk unit"
printf '%s\n' '[Timer]' 'Unit=custom.service' > "${systemd_check_timer}"
systemd_invalid_timer_out="$(systemd_check_run 2>&1 || true)"
assert_contains "${systemd_invalid_timer_out}" \
  "[BROKEN] Scheduled GC systemd timer does not declare exactly one Unit=vibeguard-gc.service:" \
  "payload doctor rejects an active timer with an unintended unit target"
printf '%s\n' '[Timer]' 'Unit=vibeguard-gc.service' > "${systemd_check_timer}"

systemd_version_target="${SYSTEMD_CHECK_HOME}/.vibeguard/dist/1.2.3/scripts/gc/gc-scheduled.sh"
printf '%s\n' '[Service]' \
  "ExecStart=/bin/bash \"${systemd_version_target}\"" \
  > "${systemd_check_service}"
systemd_version_out="$(systemd_check_run 2>&1 || true)"
assert_contains "${systemd_version_out}" "[BROKEN] Scheduled GC systemd target drift:" \
  "payload doctor rejects version-specific systemd target"
assert_not_contains "${systemd_version_out}" "[OK] Scheduled GC active via systemd" \
  "version-specific systemd target is never reported healthy"

printf '%s\n' '[Service]' \
  'ExecStart=/bin/bash "/usr/local/bin/custom-gc-scheduled.sh"' \
  > "${systemd_check_service}"
systemd_custom_out="$(systemd_check_run 2>&1 || true)"
assert_contains "${systemd_custom_out}" "[BROKEN] Scheduled GC systemd target drift:" \
  "payload doctor rejects custom systemd target"
systemd_custom_json="$(systemd_check_run --json 2>&1 || true)"
assert_json_path "${systemd_custom_json}" \
  'any(e["level"] == "BROKEN" and "systemd target drift" in e["message"] for e in d["events"])' \
  "True" "payload JSON doctor reports the same broken custom target"

rm -f "${systemd_check_service}"
systemd_missing_out="$(systemd_check_run 2>&1 || true)"
assert_contains "${systemd_missing_out}" "[BROKEN] Scheduled GC systemd service missing" \
  "payload doctor rejects active timer with missing service"
assert_not_contains "${systemd_missing_out}" "[OK] Scheduled GC active via systemd" \
  "missing systemd service is never reported healthy"

# --- Backwards-compat exit code contract ---
header "exit code contract"
# Default mode must keep exiting 0 even on a broken install, so existing
# callers (tests/test_setup.sh, downstream CI scripts) do not regress.
bash "${SETUP_SCRIPT}" --check >/dev/null 2>&1
default_rc=$?
assert_eq "$default_rc" "0" "default mode: exit 0 regardless of health (compat)"

BROKEN_HOME="$(mktemp -d)"
HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" doctor >/dev/null 2>&1
doctor_rc=$?
assert_eq "$doctor_rc" "0" "doctor command: exit 0 on broken health (compat)"

# shellcheck source=setup/runtime_config_check_tests.sh
source "${REPO_DIR}/tests/setup/runtime_config_check_tests.sh"

# --no-summary must also keep exiting 0.
bash "${SETUP_SCRIPT}" --check --no-summary >/dev/null 2>&1
no_sum_rc=$?
assert_eq "$no_sum_rc" "0" "no-summary mode: exit 0 (compat)"

verify_install_no_summary_out="$(HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" verify-install --no-summary 2>&1)"
verify_install_no_summary_rc=$?
assert_eq "$verify_install_no_summary_rc" "64" "verify-install --no-summary: rejected"
assert_contains "$verify_install_no_summary_out" "verify-install does not support --no-summary" "verify-install --no-summary: explains rejection"

verify_project_no_summary_out="$(HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" verify-project --no-summary 2>&1)"
verify_project_no_summary_rc=$?
assert_eq "$verify_project_no_summary_rc" "64" "verify-project --no-summary: rejected"
assert_contains "$verify_project_no_summary_out" "verify-project does not support --no-summary" "verify-project --no-summary: explains rejection"

verify_dev_repo_no_summary_out="$(HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" verify-dev-repo --no-summary 2>&1)"
verify_dev_repo_no_summary_rc=$?
assert_eq "$verify_dev_repo_no_summary_rc" "64" "verify-dev-repo --no-summary: rejected"
assert_contains "$verify_dev_repo_no_summary_out" "verify-dev-repo does not support --no-summary" "verify-dev-repo --no-summary: explains rejection"

legacy_install_no_summary_out="$(HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" --check --install --no-summary 2>&1)"
legacy_install_no_summary_rc=$?
assert_eq "$legacy_install_no_summary_rc" "64" "--check --install --no-summary: rejected"
assert_contains "$legacy_install_no_summary_out" "--check --install does not support --no-summary" "--check --install --no-summary: explains rejection"

legacy_strict_no_summary_out="$(HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" --check --strict --no-summary 2>&1)"
legacy_strict_no_summary_rc=$?
assert_eq "$legacy_strict_no_summary_rc" "64" "--check --strict --no-summary: rejected"
assert_contains "$legacy_strict_no_summary_out" "--check --strict does not support --no-summary" "--check --strict --no-summary: explains rejection"

legacy_json_no_summary_out="$(HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" --check --json --no-summary 2>&1)"
legacy_json_no_summary_rc=$?
assert_eq "$legacy_json_no_summary_rc" "64" "--check --json --no-summary: rejected"
assert_contains "$legacy_json_no_summary_out" "--check --json does not support --no-summary" "--check --json --no-summary: explains rejection"

# --strict, --install, and --json should reflect the verdict in the exit code.
# We can only assert that the result is one of {0, 1, 2}.
bash "${SETUP_SCRIPT}" --check --strict >/dev/null 2>&1
strict_rc=$?
TOTAL=$((TOTAL + 1))
if [[ "$strict_rc" == "0" || "$strict_rc" == "1" || "$strict_rc" == "2" ]]; then
  green "strict mode: exit code in {0,1,2} (got ${strict_rc})"; PASS=$((PASS + 1))
else
  red "strict mode: unexpected exit code ${strict_rc}"; FAIL=$((FAIL + 1))
fi

bash "${SETUP_SCRIPT}" --check --install >/dev/null 2>&1
install_rc=$?
TOTAL=$((TOTAL + 1))
if [[ "$install_rc" == "0" || "$install_rc" == "2" ]]; then
  green "install mode: exit code in {0,2} (got ${install_rc})"; PASS=$((PASS + 1))
else
  red "install mode: unexpected exit code ${install_rc}"; FAIL=$((FAIL + 1))
fi

bash "${SETUP_SCRIPT}" --check --json >/dev/null 2>&1
json_rc=$?
TOTAL=$((TOTAL + 1))
if [[ "$json_rc" == "0" || "$json_rc" == "1" || "$json_rc" == "2" ]]; then
  green "json mode: exit code in {0,1,2} (got ${json_rc})"; PASS=$((PASS + 1))
else
  red "json mode: unexpected exit code ${json_rc}"; FAIL=$((FAIL + 1))
fi

HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" verify-install >/dev/null 2>&1
verify_install_rc=$?
assert_eq "$verify_install_rc" "2" "verify-install command: broken required state exits 2"

verify_project_json_out="$(HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" verify-project --json 2>&1)"
verify_project_json_rc=$?
assert_eq "$verify_project_json_rc" "2" "verify-project --json: broken state exits 2"
TOTAL=$((TOTAL + 1))
if printf '%s' "$verify_project_json_out" | python3 -c 'import json,sys;json.loads(sys.stdin.read())' 2>/dev/null; then
  green "verify-project --json: output parses"; PASS=$((PASS + 1))
else
  red "verify-project --json: output failed to parse"; FAIL=$((FAIL + 1))
fi
assert_json_path "$verify_project_json_out" 'd["verdict"]' "broken" "verify-project --json: verdict broken"

HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" verify-dev-repo >/dev/null 2>&1
verify_dev_repo_rc=$?
assert_eq "$verify_dev_repo_rc" "2" "verify-dev-repo command: broken state exits 2"

# --- Summary ---
if [[ -e "${STALE_RUNTIME_MARKER}" ]]; then
  printf 'ERROR: stale setup runtime was invoked after the current runtime pin\n' >&2
  exit 1
fi

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
  printf '\033[32mAll %d/%d tests passed\033[0m\n' "$PASS" "$TOTAL"
  exit 0
else
  printf '\033[31m%d/%d tests failed\033[0m\n' "$FAIL" "$TOTAL"
  exit 1
fi
