scheduler_receipt_guard_home="${TMP_HOME}/scheduler-receipt-guard-home"
scheduler_receipt_guard_dir="${scheduler_receipt_guard_home}/.config/systemd/user"
mkdir -p "${scheduler_receipt_guard_dir}" \
  "${scheduler_receipt_guard_home}/.vibeguard/scheduler-ownership"
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/custom-gc' \
  > "${scheduler_receipt_guard_dir}/vibeguard-gc.service"
printf '%s\n' '[Timer]' 'OnCalendar=daily' \
  > "${scheduler_receipt_guard_dir}/vibeguard-gc.timer"
scheduler_receipt_guard_before="$(
  shasum -a 256 \
    "${scheduler_receipt_guard_dir}/vibeguard-gc.service" \
    "${scheduler_receipt_guard_dir}/vibeguard-gc.timer"
)"
set +e
scheduler_receipt_guard_out="$(
  HOME="${scheduler_receipt_guard_home}" \
    CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" \
    VIBEGUARD_TEST_UNAME=Linux \
    bash "${REPO_DIR}/setup.sh" --yes --with-scheduler 2>&1
)"
scheduler_receipt_guard_rc=$?
set -e
assert_cmd "special scheduler receipt fails explicit install before mutation" \
  test "${scheduler_receipt_guard_rc}" -ne 0
assert_contains "${scheduler_receipt_guard_out}" \
  "scheduler ownership receipt must be absent or a regular non-symlink file" \
  "special receipt failure is explicit"
assert_cmd "receipt directory preserves scheduler files byte-for-byte" bash -c \
  'test "$(shasum -a 256 "$1" "$2")" = "$3"' _ \
  "${scheduler_receipt_guard_dir}/vibeguard-gc.service" \
  "${scheduler_receipt_guard_dir}/vibeguard-gc.timer" \
  "${scheduler_receipt_guard_before}"
assert_cmd "receipt directory leaves systemd enable state unchanged" \
  test ! -e "${scheduler_receipt_guard_home}/.systemctl-vibeguard-gc-active"

malformed_receipt_home="${TMP_HOME}/scheduler-malformed-receipt-home"
malformed_receipt_plist="${malformed_receipt_home}/Library/LaunchAgents/com.vibeguard.gc.plist"
malformed_receipt_path="${malformed_receipt_home}/.vibeguard/scheduler-ownership"
malformed_receipt_bin="${TMP_HOME}/scheduler-malformed-receipt-bin"
malformed_receipt_launchctl_log="${TMP_HOME}/scheduler-malformed-receipt-launchctl.log"
malformed_receipt_launchctl_delegate="$(command -v launchctl)"
mkdir -p "$(dirname "${malformed_receipt_plist}")" \
  "$(dirname "${malformed_receipt_path}")" "${malformed_receipt_bin}"
sed -e "s|__VIBEGUARD_DIR__|${REPO_DIR}|g" \
  -e "s|__HOME__|${malformed_receipt_home}|g" \
  "${REPO_DIR}/scripts/setup/com.vibeguard.gc.plist" > "${malformed_receipt_plist}"
printf 'schema=1\nkind=launchd\nphase=managed\n' > "${malformed_receipt_path}"
touch "${malformed_receipt_home}/.launchctl-vibeguard-loaded"
printf '%s\n' "${REPO_DIR}/scripts/gc/gc-scheduled.sh" \
  > "${malformed_receipt_home}/.launchctl-vibeguard-target"
printf '%s\n' "${malformed_receipt_plist}" \
  > "${malformed_receipt_home}/.launchctl-vibeguard-plist"
malformed_receipt_before="$(
  shasum -a 256 "${malformed_receipt_plist}" "${malformed_receipt_path}" \
    "${malformed_receipt_home}/.launchctl-vibeguard-loaded" \
    "${malformed_receipt_home}/.launchctl-vibeguard-target" \
    "${malformed_receipt_home}/.launchctl-vibeguard-plist"
)"
cat > "${malformed_receipt_bin}/launchctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${malformed_receipt_launchctl_log}"
exec "${malformed_receipt_launchctl_delegate}" "\$@"
SH
chmod +x "${malformed_receipt_bin}/launchctl"
set +e
malformed_receipt_out="$(
  HOME="${malformed_receipt_home}" \
    PATH="${malformed_receipt_bin}:${PATH}" \
    CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" \
    VIBEGUARD_TEST_UNAME=Darwin \
    bash "${REPO_DIR}/setup.sh" --yes --with-scheduler 2>&1
)"
malformed_receipt_rc=$?
set -e
assert_cmd "malformed regular receipt blocks explicit scheduler refresh" \
  test "${malformed_receipt_rc}" -ne 0
assert_contains "${malformed_receipt_out}" "scheduler ownership receipt is invalid" \
  "malformed receipt failure is explicit"
assert_cmd "malformed receipt preserves plist, receipt, and loaded job state" bash -c \
  'test "$(shasum -a 256 "$1" "$2" "$3" "$4" "$5")" = "$6"' _ \
  "${malformed_receipt_plist}" "${malformed_receipt_path}" \
  "${malformed_receipt_home}/.launchctl-vibeguard-loaded" \
  "${malformed_receipt_home}/.launchctl-vibeguard-target" \
  "${malformed_receipt_home}/.launchctl-vibeguard-plist" \
  "${malformed_receipt_before}"
assert_cmd "malformed receipt performs no launchctl bootout or bootstrap" \
  test ! -s "${malformed_receipt_launchctl_log}"

wrong_kind_home="${TMP_HOME}/scheduler-wrong-kind-home"
wrong_kind_plist="${wrong_kind_home}/Library/LaunchAgents/com.vibeguard.gc.plist"
mkdir -p "$(dirname "${wrong_kind_plist}")" "${wrong_kind_home}/.vibeguard"
printf 'custom launchd scheduler\n' > "${wrong_kind_plist}"
printf 'schema=1\nkind=launchd\nplist_sha256=%s\n' \
  "$(shasum -a 256 "${wrong_kind_plist}" | awk '{print $1}')" \
  > "${wrong_kind_home}/.vibeguard/scheduler-ownership"
wrong_kind_before="$(
  shasum -a 256 "${wrong_kind_plist}" \
    "${wrong_kind_home}/.vibeguard/scheduler-ownership"
)"
set +e
wrong_kind_out="$(
  HOME="${wrong_kind_home}" \
    CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" \
    VIBEGUARD_TEST_UNAME=Linux \
    bash "${REPO_DIR}/setup.sh" --yes --with-scheduler 2>&1
)"
wrong_kind_rc=$?
set -e
assert_cmd "wrong-platform regular receipt blocks explicit scheduler install" \
  test "${wrong_kind_rc}" -ne 0
assert_contains "${wrong_kind_out}" "does not match Linux systemd scheduler" \
  "wrong-platform explicit install failure is actionable"
assert_cmd "wrong-platform receipt creates no systemd scheduler" bash -c \
  'test ! -e "$1" && test ! -e "$2"' _ \
  "${wrong_kind_home}/.config/systemd/user/vibeguard-gc.service" \
  "${wrong_kind_home}/.config/systemd/user/vibeguard-gc.timer"
assert_cmd "wrong-platform regular receipt and plist remain byte-identical" bash -c \
  'test "$(shasum -a 256 "$1" "$2")" = "$3"' _ \
  "${wrong_kind_plist}" "${wrong_kind_home}/.vibeguard/scheduler-ownership" \
  "${wrong_kind_before}"

regular_receipt_home="${TMP_HOME}/scheduler-regular-receipt-home"
mkdir -p "${regular_receipt_home}/.vibeguard"
printf 'obsolete regular receipt\n' \
  > "${regular_receipt_home}/.vibeguard/scheduler-ownership"
regular_receipt_out="$(
  HOME="${regular_receipt_home}" \
    CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" \
    VIBEGUARD_TEST_UNAME=Linux \
    bash "${REPO_DIR}/setup.sh" --yes --with-scheduler 2>&1
)"
assert_contains "${regular_receipt_out}" "Scheduled GC installed via systemd" \
  "explicit install replaces an obsolete regular receipt"
assert_cmd "regular receipt replacement is strict managed systemd state" bash -c \
  'grep -qFx "kind=systemd" "$1" && grep -qFx "phase=managed" "$1"' _ \
  "${regular_receipt_home}/.vibeguard/scheduler-ownership"

scheduler_state_fail_home="${TMP_HOME}/scheduler-state-record-fail-home"
scheduler_state_fail_runtime="${TMP_HOME}/scheduler-state-record-fail-runtime"
cat > "${scheduler_state_fail_runtime}" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "setup-state-record-file" \
  && "\${3:-}" == "${scheduler_state_fail_home}/.vibeguard/scheduler-ownership" ]]; then
  exit 91
fi
exec "${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime" "\$@"
SH
chmod +x "${scheduler_state_fail_runtime}"
set +e
scheduler_state_fail_out="$(
  HOME="${scheduler_state_fail_home}" \
    CARGO_TARGET_DIR="${CUSTOM_CARGO_TARGET_DIR}" \
    VIBEGUARD_TEST_UNAME=Linux \
    VIBEGUARD_SETUP_RUNTIME="${scheduler_state_fail_runtime}" \
    bash "${REPO_DIR}/setup.sh" --yes --with-scheduler 2>&1
)"
scheduler_state_fail_rc=$?
set -e
assert_cmd "scheduler receipt state-record failure propagates" \
  test "${scheduler_state_fail_rc}" -ne 0
assert_contains "${scheduler_state_fail_out}" \
  "failed to record systemd scheduler ownership" \
  "scheduler state-record failure is explicit"
assert_not_contains "${scheduler_state_fail_out}" \
  "Setup complete! All components installed." \
  "scheduler state-record failure never reports setup completion"
assert_cmd "failed state record still leaves an exact regular receipt" bash -c \
  'test -f "$1" && test ! -L "$1" && grep -qFx "kind=systemd" "$1" && grep -qFx "phase=managed" "$1"' _ \
  "${scheduler_state_fail_home}/.vibeguard/scheduler-ownership"

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
gc_dir="${HOME}/.vibeguard"
gc_success="${gc_dir}/gc-last-success"
gc_attempt="${gc_dir}/gc-last-attempt"
gc_check() {
  VIBEGUARD_TEST_UNAME=Linux VIBEGUARD_TEST_NOW_EPOCH=2000000000 bash "${REPO_DIR}/setup.sh" --check "$@"
}
mkdir -p "${HOME}/.config/systemd/user" "${gc_dir}"
printf '%s\n' '[Timer]' 'Unit=vibeguard-gc.service' \
  > "${HOME}/.config/systemd/user/vibeguard-gc.timer"
printf '%s\n' '[Service]' \
  "ExecStart=/bin/bash \"${REPO_DIR}/scripts/gc/gc-scheduled.sh\"" \
  > "${HOME}/.config/systemd/user/vibeguard-gc.service"
rm -f "${HOME}/.systemctl-vibeguard-gc-active" "${gc_success}" "${gc_attempt}" "${gc_dir}/gc-systemd.log" "${gc_dir}/gc-cron.log"
gc_inactive_out="$(gc_check)"
assert_not_contains "${gc_inactive_out}" "Scheduled GC execution freshness" "inactive systemd timer does not run freshness"
touch "${HOME}/.systemctl-vibeguard-gc-active"

printf '2000000000\n' > "${gc_success}"
gc_fresh_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
assert_contains "${gc_fresh_out}" "last success 0s ago" "freshness accepts age zero"
printf '1999992801\n' > "${gc_success}"
gc_before_boundary_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
assert_contains "${gc_before_boundary_out}" "[OK] Scheduled GC execution freshness" "freshness accepts interval minus one second"
printf '1999992800\n' > "${gc_success}"
gc_boundary_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
assert_contains "${gc_boundary_out}" "[WARN] Scheduled GC execution freshness stale" "freshness rejects exact interval boundary"
printf '2000000001\n' > "${gc_success}"
gc_future_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
assert_contains "${gc_future_out}" "[WARN] Scheduled GC execution freshness invalid" "freshness rejects future success"
for gc_bad_value in "" garbled; do
  printf '%s\n' "${gc_bad_value}" > "${gc_success}"
  gc_invalid_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
  assert_contains "${gc_invalid_out}" "[WARN] Scheduled GC execution freshness invalid" "freshness rejects ${gc_bad_value:-empty} success state"
done
rm -f "${gc_success}"
gc_missing_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
assert_contains "${gc_missing_out}" "[WARN] Scheduled GC execution freshness invalid" "freshness warns when success state is missing"
printf '1999999999\n' > "${gc_success}"
chmod 000 "${gc_success}"
gc_unreadable_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
chmod 600 "${gc_success}"
assert_contains "${gc_unreadable_out}" "[WARN] Scheduled GC execution freshness invalid" "freshness rejects unreadable success state"

printf '1999395201\n' > "${gc_success}"
gc_default_interval_out="$(gc_check)"
assert_contains "${gc_default_interval_out}" "[OK] Scheduled GC execution freshness" "freshness uses default 168-hour interval"
gc_project_config="${TMP_HOME}/gc-freshness-project.json"
printf '{"gc":{"catchup_interval_hours":1}}\n' > "${gc_project_config}"
printf '1999996000\n' > "${gc_success}"
gc_project_interval_out="$(VIBEGUARD_PROJECT_CONFIG="${gc_project_config}" gc_check)"
assert_contains "${gc_project_interval_out}" "[WARN] Scheduled GC execution freshness stale" "freshness reads project interval"
gc_env_interval_out="$(VIBEGUARD_PROJECT_CONFIG="${gc_project_config}" VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
assert_contains "${gc_env_interval_out}" "[OK] Scheduled GC execution freshness" "freshness environment interval overrides project config"
assert_gc_checker_repo_config_pinned

printf '1999992800\n' > "${gc_success}"
rm -f "${gc_attempt}"
{ printf '[ERROR] outside bounded tail\n'; for _ in {1..201}; do printf 'noise\n'; done; printf '[ERROR] Operation not permitted: latest systemd wrapper\n'; } > "${gc_dir}/gc-systemd.log"
printf '[ERROR] old internal\nGC completed with errors: latest internal\n' > "${gc_dir}/gc-cron.log"
gc_evidence_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
assert_contains "${gc_evidence_out}" "wrapper evidence (gc-systemd.log): [ERROR] Operation not permitted: latest systemd wrapper" "systemd freshness shows last bounded wrapper failure without attempt"
assert_contains "${gc_evidence_out}" "internal evidence (gc-cron.log): GC completed with errors: latest internal" "systemd freshness labels shared internal log"
assert_not_contains "${gc_evidence_out}" "outside bounded tail" "wrapper evidence excludes failures outside bounded tail"
assert_not_contains "${gc_evidence_out}" "old internal" "internal evidence selects only the last actionable line"
assert_contains "${gc_evidence_out}" "bash setup.sh --yes --with-scheduler" "unhealthy freshness suggests scheduler re-registration"
assert_contains "${gc_evidence_out}" "protected directories" "permission evidence suggests moving protected checkout"
assert_contains "${gc_evidence_out}" "scheduler disk access" "permission evidence suggests scheduler disk access"
printf '1999992900\n' > "${gc_attempt}"
gc_attempt_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
assert_contains "${gc_attempt_out}" "execution attempt 1999992900 is newer than last success 1999992800" "newer optional attempt is correlated"
printf 'corrupt\n' > "${gc_attempt}"
gc_corrupt_attempt_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
assert_contains "${gc_corrupt_attempt_out}" "latest systemd wrapper" "corrupt attempt does not suppress wrapper evidence"

rm -f "${gc_attempt}" "${gc_dir}/gc-systemd.log" "${gc_dir}/gc-cron.log"
gc_no_evidence_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
assert_contains "${gc_no_evidence_out}" "no actionable failure found in bounded log tails" "missing logs preserve generic freshness warning"
assert_contains "${gc_no_evidence_out}" "bash setup.sh --yes --with-scheduler" "missing logs preserve re-registration hint"
printf '[ERROR] unreadable wrapper\n' > "${gc_dir}/gc-systemd.log"
printf '[ERROR] unreadable internal\n' > "${gc_dir}/gc-cron.log"
chmod 000 "${gc_dir}/gc-systemd.log" "${gc_dir}/gc-cron.log"
gc_unreadable_logs_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
chmod 600 "${gc_dir}/gc-systemd.log" "${gc_dir}/gc-cron.log"
assert_contains "${gc_unreadable_logs_out}" "no actionable failure found in bounded log tails" "unreadable logs preserve generic freshness warning"
printf 'no actionable match\n' > "${gc_dir}/gc-systemd.log"
printf 'no actionable match\n' > "${gc_dir}/gc-cron.log"
gc_digest_before="$(shasum -a 256 "${gc_success}" "${gc_dir}/gc-systemd.log" "${gc_dir}/gc-cron.log" "${HOME}/.systemctl-vibeguard-gc-active")"
gc_repeat_one="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
gc_repeat_two="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"
gc_digest_after="$(shasum -a 256 "${gc_success}" "${gc_dir}/gc-systemd.log" "${gc_dir}/gc-cron.log" "${HOME}/.systemctl-vibeguard-gc-active")"
assert_cmd "freshness check leaves state and logs unchanged" test "${gc_digest_before}" = "${gc_digest_after}"
assert_cmd "freshness classification is idempotent" test "$(grep -F 'Scheduled GC execution freshness' <<< "${gc_repeat_one}")" = "$(grep -F 'Scheduled GC execution freshness' <<< "${gc_repeat_two}")"

set +e
gc_default_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check)"; gc_default_rc=$?
gc_strict_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check --strict)"; gc_strict_rc=$?
gc_json_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check --json)"; gc_json_rc=$?
gc_install_out="$(VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 gc_check --install)"; gc_install_rc=$?
set -e
assert_cmd "freshness-only WARN keeps default check exit zero" test "${gc_default_rc}" -eq 0
assert_contains "${gc_default_out}" "[WARN] Scheduled GC execution freshness stale" "default mode keeps freshness classification"
assert_cmd "freshness-only WARN makes strict check degraded" test "${gc_strict_rc}" -eq 1
assert_contains "${gc_strict_out}" "DEGRADED" "strict freshness WARN reports DEGRADED"
assert_cmd "freshness-only WARN makes JSON check degraded" test "${gc_json_rc}" -eq 1
assert_cmd "JSON freshness output is one degraded document with WARN event" python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["verdict"] == "degraded" and any(e["level"] == "WARN" and "Scheduled GC execution freshness" in e["message"] for e in d["events"])' "${gc_json_out}"
assert_cmd "freshness-only WARN keeps install check exit zero" test "${gc_install_rc}" -eq 0
assert_contains "${gc_install_out}" "[WARN] Scheduled GC execution freshness stale" "install mode keeps freshness classification"

printf '%s\n' "${REPO_DIR}/scripts/gc/gc-scheduled.sh" > "${HOME}/.launchctl-vibeguard-target"
touch "${HOME}/.launchctl-vibeguard-loaded"
printf '[ERROR] launchd wrapper failure\n' > "${gc_dir}/gc-launchd.log"
printf '[ERROR] systemd wrapper must stay hidden\n' > "${gc_dir}/gc-systemd.log"
gc_launchd_out="$(VIBEGUARD_TEST_UNAME=Darwin VIBEGUARD_TEST_NOW_EPOCH=2000000000 VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS=2 bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${gc_launchd_out}" "wrapper evidence (gc-launchd.log): [ERROR] launchd wrapper failure" "launchd freshness uses launchd wrapper log"
assert_not_contains "${gc_launchd_out}" "systemd wrapper must stay hidden" "launchd freshness does not read systemd wrapper log"
printf '%s\n' "${TMP_HOME}/drifted/gc-scheduled.sh" > "${HOME}/.launchctl-vibeguard-target"
gc_launchd_drift_out="$(VIBEGUARD_TEST_UNAME=Darwin bash "${REPO_DIR}/setup.sh" --check)"
assert_not_contains "${gc_launchd_drift_out}" "Scheduled GC execution freshness" "drifted active launchd target does not run freshness"
printf '%s\n' "${REPO_DIR}/scripts/gc/gc-scheduled.sh" > "${HOME}/.launchctl-vibeguard-target"
assert_launchd_gc_edge_gates
if [[ "$(uname)" == "Darwin" ]]; then
  stale_scheduler_dir="${TMP_HOME}/stale-vibeguard"
  mkdir -p "${stale_scheduler_dir}"
  sed -e "s|__VIBEGUARD_DIR__|${stale_scheduler_dir}|g" -e "s|__HOME__|${HOME}|g" \
    "${REPO_DIR}/scripts/setup/com.vibeguard.gc.plist" \
    > "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
  stale_plist_check_out="$(bash "${REPO_DIR}/setup.sh" --check 2>&1 || true)"
  assert_contains "${stale_plist_check_out}" "[OK] Scheduled GC active via launchd" "--check keeps active scheduled GC healthy when only persisted plist drifts"
  assert_contains "${stale_plist_check_out}" "[WARN] Scheduled GC plist target drift:" "--check reports persisted scheduled GC target drift"
  assert_not_contains "${stale_plist_check_out}" "[BROKEN] Scheduled GC launchd target drift:" "--check does not treat plist-only scheduled GC drift as active target drift"
  launchctl bootout "gui/$(id -u)/com.vibeguard.gc" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
  stale_scheduler_check_out="$(bash "${REPO_DIR}/setup.sh" --check 2>&1 || true)"
  assert_contains "${stale_scheduler_check_out}" "[BROKEN] Scheduled GC launchd target drift:" "--check reports loaded scheduled GC target drift"
  assert_contains "${stale_scheduler_check_out}" "${stale_scheduler_dir}/scripts/gc/gc-scheduled.sh" "--check reports stale scheduled GC target path"
  assert_not_contains "${stale_scheduler_check_out}" "[OK] Scheduled GC active via launchd" "--check does not treat stale scheduled GC as healthy"
  launchctl bootout "gui/$(id -u)/com.vibeguard.gc" 2>/dev/null || true
  rm -f "${HOME}/.launchctl-vibeguard-loaded" "${HOME}/.launchctl-vibeguard-target" "${HOME}/.launchctl-vibeguard-plist" "${HOME}/Library/LaunchAgents/com.vibeguard.gc.plist"
fi
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
assert_contains "${installed_git_hook_check_out}" "[OK] Installed hooks+guards snapshot matches repo-path HEAD" "--check reports installed snapshot healthy"
tracked_snapshot_file="${HOME}/.vibeguard/installed/schemas/vibeguard-project.schema.json"
tracked_snapshot_backup="${TMP_HOME}/tracked-snapshot-schema.json"
cp "${tracked_snapshot_file}" "${tracked_snapshot_backup}"
printf '\n# local drift\n' >> "${tracked_snapshot_file}"
installed_snapshot_drift_check_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_contains "${installed_snapshot_drift_check_out}" "DRIFT: ${tracked_snapshot_file} (checksum mismatch)" "--check reports installed snapshot file checksum drift"
assert_contains "${installed_snapshot_drift_check_out}" "[WARN] Run 'bash setup.sh' to repair drifted files" "--check tells users how to repair installed snapshot drift"
cp "${tracked_snapshot_backup}" "${tracked_snapshot_file}"
restored_snapshot_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${restored_snapshot_check_out}" "[OK] Total tracked:" "--check reports clean install state after restoring tracked snapshot file"
assert_not_contains "${restored_snapshot_check_out}" "DRIFT: ${tracked_snapshot_file}" "--check stops reporting installed snapshot drift after restore"
vibeguard_command="${HOME}/.vibeguard/installed/bin/vibeguard"
rm "${vibeguard_command}"
ln -s /bin/echo "${vibeguard_command}"
set +e
retargeted_command_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1)"
retargeted_command_rc=$?
set -e
assert_cmd "--check --strict rejects retargeted vibeguard command" test "${retargeted_command_rc}" -eq 2
assert_contains "${retargeted_command_out}" "[BROKEN] vibeguard command target drift: /bin/echo (expected: vibeguard-runtime)" "--check reports vibeguard command target drift"
rm "${vibeguard_command}"
ln -s vibeguard-runtime "${vibeguard_command}"
runtime_backup="${TMP_HOME}/installed-vibeguard-runtime.backup"
cp "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" "${runtime_backup}"
cat > "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  version)
    printf '0.0.0\n'
    ;;
  setup-state-list-symlinks-under)
    ;;
  setup-state-check-drift)
    printf 'STATUS: CLEAN\n'
    printf 'Total tracked: 1\n'
    ;;
  setup-state-list)
    printf 'Profile: core\n'
    ;;
  *)
    ;;
esac
SH
chmod +x "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
set +e
mismatched_runtime_check_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1)"
mismatched_runtime_check_rc=$?
set -e
assert_cmd "--check --strict exits broken for mismatched runtime version" test "${mismatched_runtime_check_rc}" -eq 2
assert_contains "${mismatched_runtime_check_out}" "[BROKEN] vibeguard-runtime version mismatch: 0.0.0" "--check reports mismatched runtime version"
cp "${runtime_backup}" "${HOME}/.vibeguard/installed/bin/vibeguard-runtime"
snapshot_repo_path_check="${TMP_HOME}/snapshot-repo-path-check"
mkdir -p "${snapshot_repo_path_check}"
git -C "${snapshot_repo_path_check}" init -q
git -C "${snapshot_repo_path_check}" config user.email "vibeguard@example.test"
git -C "${snapshot_repo_path_check}" config user.name "VibeGuard Test"
printf 'snapshot repo\n' > "${snapshot_repo_path_check}/README.md"
git -C "${snapshot_repo_path_check}" add README.md
git -C "${snapshot_repo_path_check}" commit -q -m "seed snapshot repo"
printf '%s' "${snapshot_repo_path_check}" > "${HOME}/.vibeguard/repo-path"
git -C "${snapshot_repo_path_check}" rev-parse --short HEAD > "${HOME}/.vibeguard/installed/version"
snapshot_repo_path_check_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1 || true)"
assert_contains "${snapshot_repo_path_check_out}" "[OK] Installed hooks+guards snapshot matches repo-path HEAD" "--check compares installed snapshot against repo-path HEAD"
printf '%s' "${REPO_DIR}" > "${HOME}/.vibeguard/repo-path"
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
rm -f "${HOME}/.claude/skills/eval-harness"
ln -s "${wrong_claude_skill_target}" "${HOME}/.claude/skills/eval-harness"
drift_claude_skill_check_out="$(bash "${REPO_DIR}/setup.sh" --check 2>&1 || true)"
assert_contains "${drift_claude_skill_check_out}" "[BROKEN] eval-harness skill symlink target drift:" "--check reports Claude skill symlink target drift"
rm -f "${HOME}/.claude/skills/eval-harness"
ln -s "${HOME}/.vibeguard/installed/skills/eval-harness" "${HOME}/.claude/skills/eval-harness"
wrong_rule_target="${TMP_HOME}/wrong-security-rule.md"
printf '## U-17: Wrong source\n' > "${wrong_rule_target}"
# GH-541: the core profile no longer front-injects the tree, so create the
# common/ dir before injecting the drift/stale symlinks the --check must catch.
mkdir -p "${HOME}/.claude/rules/vibeguard/common"
rm -f "${HOME}/.claude/rules/vibeguard/common/security.md"
ln -s "${wrong_rule_target}" "${HOME}/.claude/rules/vibeguard/common/security.md"
drift_claude_rule_check_out="$(bash "${REPO_DIR}/setup.sh" --check 2>&1 || true)"
assert_contains "${drift_claude_rule_check_out}" "[BROKEN] Native rule symlink target drift:" "--check reports native rule symlink target drift"
rm -f "${HOME}/.claude/rules/vibeguard/common/security.md"
ln -s "${HOME}/.vibeguard/installed/rules/claude-rules/common/security.md" "${HOME}/.claude/rules/vibeguard/common/security.md"
ln -s "${HOME}/.vibeguard/installed/rules/claude-rules/common/workflow.md" "${HOME}/.claude/rules/vibeguard/common/stale-not-in-manifest.md"
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
ln -s "${HOME}/.vibeguard/installed/.claude/commands/vg" "${HOME}/.claude/commands/vg"
assert_contains "${installed_git_hook_check_out}" "[OK] VibeGuard repo pre-commit hook installed" "--check reports repo pre-commit hook healthy"
assert_contains "${installed_git_hook_check_out}" "[OK] VibeGuard repo pre-push hook installed" "--check reports repo pre-push hook healthy"
fake_wrapper_repo="${TMP_HOME}/fake-wrapper-repo"
mkdir -p "${fake_wrapper_repo}/hooks/git"
printf '%s' "${fake_wrapper_repo}" > "${HOME}/.vibeguard/repo-path"
stable_fake_repo_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
assert_contains "${stable_fake_repo_check_out}" "[OK] Execution mode: installed snapshot" "--check stable mode ignores fake repo-path for execution"
assert_not_contains "${stable_fake_repo_check_out}" "hook execution source missing: ${fake_wrapper_repo}" "--check stable mode does not use repo-path as git hook source"
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
assert_cmd "~/.claude/skills/eval-harness exists after installation" test -L "${HOME}/.claude/skills/eval-harness"
assert_cmd "~/.claude/skills/iterative-retrieval exists after installation" test -L "${HOME}/.claude/skills/iterative-retrieval"
assert_cmd "unowned same-name Codex skill is preserved during retirement" test -f "${HOME}/.codex/skills/vibeguard/STALE.txt"
for retired_skill in agentsmd-audit trajectory-review plan-flow fixflow optflow plan-mode auto-optimize; do
  assert_cmd "~/.codex/skills/${retired_skill} is not installed" test ! -e "${HOME}/.codex/skills/${retired_skill}"
done
assert_cmd "all manifest Claude skill links are installed" assert_manifest_skill_links_installed "~/.claude/skills/" "${HOME}/.claude/skills"
assert_cmd "all manifest Codex skill links are installed" assert_manifest_skill_links_installed "~/.codex/skills/" "${HOME}/.codex/skills"
assert_cmd "No longer write to mcpServers after installation" bash -c "! grep -q 'mcpServers' '${HOME}/.claude/settings.json'"
assert_cmd "settings helper detects pre hooks configured" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target pre-hooks
assert_cmd "settings helper detects post hooks configured" python3 "${SETTINGS_HELPER}" check --settings-file "${HOME}/.claude/settings.json" --target post-hooks
assert_cmd "skills-loader is not enabled in the default installation" bash -c "! grep -q 'skills-loader.sh' '${HOME}/.claude/settings.json'"
assert_cmd "The default core profile does not enable full hooks" bash -c "python3 '${SETTINGS_HELPER}' check --settings-file '${HOME}/.claude/settings.json' --target full-hooks >/dev/null 2>&1; test \$? -ne 0"
assert_cmd "~/.codex/hooks.json exists after installation" test -f "${HOME}/.codex/hooks.json"
assert_cmd "Enable hooks feature after installation" grep -Eq '^hooks[[:space:]]*=[[:space:]]*true$' "${HOME}/.codex/config.toml"
assert_cmd "Codex core hooks are namespaced and exclude full-only hooks" bash -c "grep -q 'vibeguard-pre-bash-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-pre-edit-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-pre-write-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-post-edit-guard.sh' '${HOME}/.codex/hooks.json' && grep -q 'vibeguard-post-write-guard.sh' '${HOME}/.codex/hooks.json' && ! grep -q 'vibeguard-post-build-check.sh' '${HOME}/.codex/hooks.json' && ! grep -q 'vibeguard-stop-guard.sh' '${HOME}/.codex/hooks.json' && ! grep -q 'vibeguard-learn-evaluator.sh' '${HOME}/.codex/hooks.json'"
assert_cmd "Codex hooks include PermissionRequest native gates" bash -c "grep -q '\"PermissionRequest\"' '${HOME}/.codex/hooks.json' && grep -q '\"matcher\": \"Edit\"' '${HOME}/.codex/hooks.json' && grep -q '\"matcher\": \"Write\"' '${HOME}/.codex/hooks.json'"
assert_cmd "Codex runtime validates managed core hooks" "${HOME}/.vibeguard/installed/bin/vibeguard-runtime" setup-codex-hooks-check "${REPO_DIR}" "${HOME}/.codex/hooks.json" "${HOME}/.vibeguard/run-hook-codex.sh" core
assert_cmd "run-hook-codex visibly rejects non-namespaced hook names" bash -c "out=\$(printf '{\"hook_event_name\":\"PreToolUse\",\"tool_input\":{\"command\":\"rm -rf /\"}}' | bash '${REPO_DIR}/hooks/run-hook-codex.sh' pre-bash-guard.sh); grep -q 'permissionDecision' <<<\"\$out\" && grep -q 'invalid-hook-name' <<<\"\$out\""
assert_cmd "Pre-existing non-VibeGuard hook is preserved" grep -q "node ${PREEXISTING_CODEX_HOOK_SCRIPT}" "${HOME}/.codex/hooks.json"
python3 - "${HOME}/.codex/hooks.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
entry = data["hooks"]["PreToolUse"][0]
entry["hooks"].append({"type": "command", "command": "node /existing/non-vibeguard.js"})
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
set +e
setup_without_stale_repair_out="$(bash "${REPO_DIR}/setup.sh" --yes 2>&1)"
setup_without_stale_repair_rc=$?
set -e
TOTAL=$((TOTAL + 1))
if [[ "${setup_without_stale_repair_rc}" -ne 0 ]]; then
  green "setup without stale unmanaged repair fails install verification"
  PASS=$((PASS + 1))
else
  red "setup without stale unmanaged repair fails install verification (expected nonzero)"
  FAIL=$((FAIL + 1))
fi
assert_contains "${setup_without_stale_repair_out}" "repair-required unmanaged Codex blocking hook" "setup without stale unmanaged repair reports blocker"
assert_cmd "ordinary setup preserves stale unmanaged Codex hook by default" grep -q '/existing/non-vibeguard.js' "${HOME}/.codex/hooks.json"
setup_with_stale_repair_out="$(bash "${REPO_DIR}/setup.sh" --yes --repair-stale-unmanaged-hooks)"
assert_contains "${setup_with_stale_repair_out}" "Stale unmanaged Codex hooks repaired" "setup repair flag reports stale unmanaged repair"
assert_cmd "repair flag removes stale unmanaged Codex hook" bash -c "! grep -q '/existing/non-vibeguard.js' '${HOME}/.codex/hooks.json'"
assert_cmd "repair flag preserves valid third-party Codex hook" grep -q "node ${PREEXISTING_CODEX_HOOK_SCRIPT}" "${HOME}/.codex/hooks.json"
assert_cmd "Codex hooks include managed + preserved entries" python3 -c "import json; data=json.load(open('${HOME}/.codex/hooks.json')); total=sum(len(entries) for entries in data.get('hooks', {}).values() if isinstance(entries, list)); raise SystemExit(0 if total >= 5 else 1)"
assert_cmd "~/.claude/CLAUDE.md includes the chat contract anchor after installation" grep -qF "${CHAT_CONTRACT_ANCHOR}" "${HOME}/.claude/CLAUDE.md"
assert_cmd "~/.claude/CLAUDE.md rule banner matches expected rules" assert_claude_rule_banner_matches_expected_rules
assert_cmd "~/.codex/AGENTS.md exists after installation" test -f "${HOME}/.codex/AGENTS.md"
assert_cmd "~/.codex/AGENTS.md includes managed markers after installation" bash -c "grep -q '<!-- vibeguard-start -->' '${HOME}/.codex/AGENTS.md' && grep -q '<!-- vibeguard-end -->' '${HOME}/.codex/AGENTS.md'"
assert_cmd "~/.codex/AGENTS.md rule banner matches expected rules" assert_codex_rule_banner_matches_expected_rules
assert_cmd "~/.codex/AGENTS.md includes key Codex-visible anchors" bash -c "grep -qF 'Compact Chat Contract' '${HOME}/.codex/AGENTS.md' && grep -qF '| W-03 |' '${HOME}/.codex/AGENTS.md' && grep -qF '| SEC-13 |' '${HOME}/.codex/AGENTS.md'"
assert_cmd "Claude receives only Claude host guidance" bash -c "grep -qF '## Claude Code host guidance' '${HOME}/.claude/CLAUDE.md' && ! grep -qF '## Codex host guidance' '${HOME}/.claude/CLAUDE.md'"
assert_cmd "Codex receives only Codex host guidance" bash -c "grep -qF '## Codex host guidance' '${HOME}/.codex/AGENTS.md' && ! grep -qF '## Claude Code host guidance' '${HOME}/.codex/AGENTS.md'"
assert_cmd "Codex global contract excludes Claude-only workflow commands" bash -c "! grep -qF '/vibeguard:' '${HOME}/.codex/AGENTS.md' && ! grep -qF 'Corrected 2 times' '${HOME}/.codex/AGENTS.md'"
assert_cmd "templates/AGENTS.md includes the chat contract anchor" grep -qF "${CHAT_CONTRACT_ANCHOR}" "${REPO_DIR}/templates/AGENTS.md"
assert_cmd "docs/CLAUDE.md.example includes the chat contract anchor" grep -qF "${CHAT_CONTRACT_ANCHOR}" "${REPO_DIR}/docs/CLAUDE.md.example"
assert_cmd "chat contract block matches across source, installed output, and templates" assert_chat_contract_blocks_match
