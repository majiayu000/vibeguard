header "setup protects user customizations"
python3 - <<'PY' "${HOME}/.claude/settings.json" "${HOME}"
import json
import sys
from pathlib import Path

settings = Path(sys.argv[1])
home = sys.argv[2]
data = json.loads(settings.read_text(encoding="utf-8"))
for entry in data["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        entry["hooks"][0]["command"] = f"flock /tmp/vibeguard.lock bash {home}/.vibeguard/run-hook.sh pre-bash-guard.sh"
settings.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
custom_settings_out="$(bash "${REPO_DIR}/setup.sh" --yes 2>&1)"
assert_contains "${custom_settings_out}" "preserving customized VibeGuard hook command for pre-bash-guard.sh" "setup warns when preserving customized hook command"
assert_contains "${custom_settings_out}" "~/.vibeguard/config.json present (preserved)" "setup preserves existing runtime config file"
assert_cmd "customized hook command is preserved by default" grep -q "flock /tmp/vibeguard.lock" "${HOME}/.claude/settings.json"
force_settings_out="$(bash "${REPO_DIR}/setup.sh" --yes --force-overwrite 2>&1)"
assert_contains "${force_settings_out}" "Mode: force-overwrite" "--force-overwrite mode is visible"
assert_cmd "--force-overwrite restores canonical hook command" bash -c "! grep -q 'flock /tmp/vibeguard.lock' '${HOME}/.claude/settings.json'"

python3 - <<'PY' "${HOME}/.claude/settings.json"
import json
import sys
from pathlib import Path

settings = Path(sys.argv[1])
data = json.loads(settings.read_text(encoding="utf-8"))
for entry in data["hooks"]["PreToolUse"]:
    if entry.get("matcher") == "Bash":
        entry["hooks"].append({"type": "command", "command": "bash /tmp/third-party-pre-bash.sh"})
        break
else:
    raise SystemExit(1)
settings.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
custom_scheduler_dir="${HOME}/.config/systemd/user"
custom_scheduler_service="${custom_scheduler_dir}/vibeguard-gc.service"
custom_scheduler_timer="${custom_scheduler_dir}/vibeguard-gc.timer"
mkdir -p "${custom_scheduler_dir}"
printf '%s\n' '[Service]' 'Environment="CUSTOM_FLAG=preserve"' \
  'ExecStart=/usr/local/bin/custom-gc' > "${custom_scheduler_service}"
printf '%s\n' '[Timer]' 'OnCalendar=Mon *-*-* 04:30:00' \
  > "${custom_scheduler_timer}"
printf '%s\n' 'schema=1' 'kind=systemd' \
  'service_sha256=0000000000000000000000000000000000000000000000000000000000000000' \
  'timer_sha256=0000000000000000000000000000000000000000000000000000000000000000' \
  > "${HOME}/.vibeguard/scheduler-ownership"
custom_scheduler_before="$(
  shasum -a 256 "${custom_scheduler_service}" "${custom_scheduler_timer}"
)"
mixed_clean_rc=0
mixed_clean_out="$(
  VIBEGUARD_TEST_UNAME=Linux bash "${REPO_DIR}/setup.sh" --clean 2>&1
)" || mixed_clean_rc=$?
assert_cmd "setup --clean fails loudly when scheduler ownership drift blocks complete cleanup" \
  test "${mixed_clean_rc}" -ne 0
assert_not_contains "${mixed_clean_out}" "VibeGuard cleaned." \
  "incomplete scheduler cleanup never reports global clean success"
assert_cmd "setup --clean preserves third-party Claude hook in mixed entry" grep -q "/tmp/third-party-pre-bash.sh" "${HOME}/.claude/settings.json"
assert_cmd "setup --clean removes VibeGuard hook from mixed entry" bash -c "! grep -q 'pre-bash-guard.sh' '${HOME}/.claude/settings.json'"
assert_contains "${mixed_clean_out}" "scheduler ownership receipt does not match" \
  "setup --clean reports drifted scheduler as unmanaged"
assert_cmd "setup --clean preserves custom scheduler Environment and schedule" bash -c \
  'test "$(shasum -a 256 "$1" "$2")" = "$3"' _ \
  "${custom_scheduler_service}" "${custom_scheduler_timer}" "${custom_scheduler_before}"
assert_cmd "setup --clean preserves drifted scheduler ownership receipt" \
  test -f "${HOME}/.vibeguard/scheduler-ownership"
rm -f "${custom_scheduler_service}" "${custom_scheduler_timer}"
rm -f "${HOME}/.vibeguard/scheduler-ownership"
# The Linux test double persists active timer state outside the unit files.
# The drift case intentionally preserves that state, so manual fixture cleanup
# must remove its marker before later install verification.
rm -f "${HOME}/.systemctl-vibeguard-gc-active"
rm -f "${HOME}/.systemctl-vibeguard-gc-enabled"

for scheduler_deactivate_case in \
  stop_failure active_after_stop service_stop_failure \
  service_active_after_stop disable_failure enabled_after_disable; do
  scheduler_deactivate_home="${TMP_HOME}/scheduler-deactivate-${scheduler_deactivate_case}-home"
  scheduler_deactivate_dir="${scheduler_deactivate_home}/.config/systemd/user"
  scheduler_deactivate_service="${scheduler_deactivate_dir}/vibeguard-gc.service"
  scheduler_deactivate_timer="${scheduler_deactivate_dir}/vibeguard-gc.timer"
  scheduler_deactivate_receipt="${scheduler_deactivate_home}/.vibeguard/scheduler-ownership"
  scheduler_deactivate_service_active="${scheduler_deactivate_home}/.systemctl-vibeguard-gc-service-active"
  mkdir -p "${scheduler_deactivate_dir}" "$(dirname "${scheduler_deactivate_receipt}")"
  printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/managed-gc' \
    > "${scheduler_deactivate_service}"
  printf '%s\n' '[Timer]' 'OnCalendar=daily' > "${scheduler_deactivate_timer}"
  printf 'schema=1\nkind=systemd\nphase=managed\nservice_sha256=%s\ntimer_sha256=%s\n' \
    "$(shasum -a 256 "${scheduler_deactivate_service}" | awk '{print $1}')" \
    "$(shasum -a 256 "${scheduler_deactivate_timer}" | awk '{print $1}')" \
    > "${scheduler_deactivate_receipt}"
  touch "${scheduler_deactivate_home}/.systemctl-vibeguard-gc-active"
  touch "${scheduler_deactivate_home}/.systemctl-vibeguard-gc-enabled"
  scheduler_deactivate_env=()
  case "${scheduler_deactivate_case}" in
    stop_failure)
      scheduler_deactivate_env+=(VIBEGUARD_TEST_SYSTEMD_STOP_FAIL=1)
      scheduler_deactivate_error="failed to stop scheduled GC systemd timer"
      ;;
    active_after_stop)
      scheduler_deactivate_env+=(VIBEGUARD_TEST_SYSTEMD_STILL_ACTIVE=1)
      scheduler_deactivate_error="is not proven inactive after stop"
      ;;
    service_stop_failure)
      touch "${scheduler_deactivate_service_active}"
      scheduler_deactivate_env+=(VIBEGUARD_TEST_SYSTEMD_SERVICE_STOP_FAIL=1)
      scheduler_deactivate_error="failed to stop scheduled GC systemd service"
      ;;
    service_active_after_stop)
      touch "${scheduler_deactivate_service_active}"
      scheduler_deactivate_env+=(VIBEGUARD_TEST_SYSTEMD_SERVICE_STILL_ACTIVE=1)
      scheduler_deactivate_error="systemd service is not proven inactive after stop"
      ;;
    disable_failure)
      scheduler_deactivate_env+=(VIBEGUARD_TEST_SYSTEMD_DISABLE_FAIL=1)
      scheduler_deactivate_error="failed to disable scheduled GC systemd timer"
      ;;
    enabled_after_disable)
      scheduler_deactivate_env+=(VIBEGUARD_TEST_SYSTEMD_STILL_ENABLED=1)
      scheduler_deactivate_error="is not proven disabled"
      ;;
  esac
  scheduler_deactivate_rc=0
  scheduler_deactivate_out="$(
    env HOME="${scheduler_deactivate_home}" VIBEGUARD_TEST_UNAME=Linux \
      "${scheduler_deactivate_env[@]}" \
      bash "${REPO_DIR}/setup.sh" --clean 2>&1
  )" || scheduler_deactivate_rc=$?
  assert_cmd "systemd ${scheduler_deactivate_case} fails clean" \
    test "${scheduler_deactivate_rc}" -ne 0
  assert_contains "${scheduler_deactivate_out}" "${scheduler_deactivate_error}" \
    "systemd ${scheduler_deactivate_case} reports the failed postcondition"
  assert_not_contains "${scheduler_deactivate_out}" "VibeGuard cleaned." \
    "systemd ${scheduler_deactivate_case} never reports clean complete"
  assert_cmd "systemd ${scheduler_deactivate_case} preserves owned units and receipt" bash -c \
    'test -f "$1" && test -f "$2" && grep -qFx "phase=cleaning" "$3"' _ \
    "${scheduler_deactivate_service}" "${scheduler_deactivate_timer}" \
    "${scheduler_deactivate_receipt}"
  case "${scheduler_deactivate_case}" in
    service_stop_failure|service_active_after_stop)
      assert_cmd "systemd ${scheduler_deactivate_case} preserves active service evidence" \
        test -f "${scheduler_deactivate_service_active}"
      ;;
  esac
done

scheduler_deactivate_success_home="${TMP_HOME}/scheduler-deactivate-success-home"
scheduler_deactivate_success_dir="${scheduler_deactivate_success_home}/.config/systemd/user"
scheduler_deactivate_success_receipt="${scheduler_deactivate_success_home}/.vibeguard/scheduler-ownership"
mkdir -p "${scheduler_deactivate_success_dir}" \
  "$(dirname "${scheduler_deactivate_success_receipt}")"
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/managed-gc' \
  > "${scheduler_deactivate_success_dir}/vibeguard-gc.service"
printf '%s\n' '[Timer]' 'OnCalendar=daily' \
  > "${scheduler_deactivate_success_dir}/vibeguard-gc.timer"
printf 'schema=1\nkind=systemd\nphase=managed\nservice_sha256=%s\ntimer_sha256=%s\n' \
  "$(shasum -a 256 "${scheduler_deactivate_success_dir}/vibeguard-gc.service" | awk '{print $1}')" \
  "$(shasum -a 256 "${scheduler_deactivate_success_dir}/vibeguard-gc.timer" | awk '{print $1}')" \
  > "${scheduler_deactivate_success_receipt}"
touch "${scheduler_deactivate_success_home}/.systemctl-vibeguard-gc-active"
touch "${scheduler_deactivate_success_home}/.systemctl-vibeguard-gc-service-active"
touch "${scheduler_deactivate_success_home}/.systemctl-vibeguard-gc-enabled"
HOME="${scheduler_deactivate_success_home}" VIBEGUARD_TEST_UNAME=Linux \
  bash "${REPO_DIR}/setup.sh" --clean >/dev/null
assert_cmd "systemd clean removes files only after inactive and disabled postconditions" bash -c \
  'test ! -e "$1" && test ! -e "$2" && test ! -e "$3" && test ! -e "$4" && test ! -e "$5" && test ! -e "$6"' _ \
  "${scheduler_deactivate_success_dir}/vibeguard-gc.service" \
  "${scheduler_deactivate_success_dir}/vibeguard-gc.timer" \
  "${scheduler_deactivate_success_receipt}" \
  "${scheduler_deactivate_success_home}/.systemctl-vibeguard-gc-active" \
  "${scheduler_deactivate_success_home}/.systemctl-vibeguard-gc-service-active" \
  "${scheduler_deactivate_success_home}/.systemctl-vibeguard-gc-enabled"

runtime_clean_home="${TMP_HOME}/scheduler-runtime-clean-home"
runtime_clean_dir="${runtime_clean_home}/.config/systemd/user"
runtime_clean_receipt="${runtime_clean_home}/.vibeguard/scheduler-ownership"
runtime_clean_enabled="${runtime_clean_home}/.systemctl-vibeguard-gc-enabled-runtime"
mkdir -p "${runtime_clean_dir}" "$(dirname "${runtime_clean_receipt}")"
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/managed-gc' \
  > "${runtime_clean_dir}/vibeguard-gc.service"
printf '%s\n' '[Timer]' 'OnCalendar=daily' \
  > "${runtime_clean_dir}/vibeguard-gc.timer"
printf 'schema=1\nkind=systemd\nphase=managed\nservice_sha256=%s\ntimer_sha256=%s\n' \
  "$(shasum -a 256 "${runtime_clean_dir}/vibeguard-gc.service" | awk '{print $1}')" \
  "$(shasum -a 256 "${runtime_clean_dir}/vibeguard-gc.timer" | awk '{print $1}')" \
  > "${runtime_clean_receipt}"
touch "${runtime_clean_home}/.systemctl-vibeguard-gc-active" \
  "${runtime_clean_home}/.systemctl-vibeguard-gc-service-active" \
  "${runtime_clean_enabled}"
HOME="${runtime_clean_home}" VIBEGUARD_TEST_UNAME=Linux \
  bash "${REPO_DIR}/setup.sh" --clean >/dev/null
assert_cmd "systemd clean removes runtime-enabled timer state and owned files" bash -c \
  'test ! -e "$1" && test ! -e "$2" && test ! -e "$3" \
    && test ! -e "$4"' _ \
  "${runtime_clean_dir}/vibeguard-gc.service" \
  "${runtime_clean_dir}/vibeguard-gc.timer" \
  "${runtime_clean_receipt}" "${runtime_clean_enabled}"

for scheduler_clean_point in after-phase after-first before-receipt; do
  scheduler_clean_home="${TMP_HOME}/scheduler-clean-${scheduler_clean_point}-home"
  scheduler_clean_bin="${TMP_HOME}/scheduler-clean-${scheduler_clean_point}-bin"
  scheduler_clean_service="${scheduler_clean_home}/.config/systemd/user/vibeguard-gc.service"
  scheduler_clean_timer="${scheduler_clean_home}/.config/systemd/user/vibeguard-gc.timer"
  scheduler_clean_receipt="${scheduler_clean_home}/.vibeguard/scheduler-ownership"
  mkdir -p "$(dirname "${scheduler_clean_service}")" \
    "$(dirname "${scheduler_clean_receipt}")" "${scheduler_clean_bin}"
  printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/managed-gc' \
    > "${scheduler_clean_service}"
  printf '%s\n' '[Timer]' 'OnCalendar=daily' > "${scheduler_clean_timer}"
  printf 'schema=1\nkind=systemd\nservice_sha256=%s\ntimer_sha256=%s\n' \
    "$(shasum -a 256 "${scheduler_clean_service}" | awk '{print $1}')" \
    "$(shasum -a 256 "${scheduler_clean_timer}" | awk '{print $1}')" \
    > "${scheduler_clean_receipt}"
  scheduler_clean_real_mv="$(command -v mv)"
  scheduler_clean_real_rm="$(command -v rm)"
  case "${scheduler_clean_point}" in
    after-phase)
      cat > "${scheduler_clean_bin}/mv" <<SH
#!/usr/bin/env bash
previous=""
last=""
for arg in "\$@"; do previous="\${last}"; last="\${arg}"; done
if [[ "\${last}" == "${scheduler_clean_receipt}" ]] \
  && grep -qFx "phase=cleaning" "\${previous}" 2>/dev/null; then
  "${scheduler_clean_real_mv}" "\$@"
  kill -KILL "\${PPID}"
  exit 137
fi
exec "${scheduler_clean_real_mv}" "\$@"
SH
      chmod +x "${scheduler_clean_bin}/mv"
      ;;
    after-first)
      cat > "${scheduler_clean_bin}/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\${arg}" == "${scheduler_clean_service}" ]]; then
    "${scheduler_clean_real_rm}" -f -- "${scheduler_clean_service}"
    kill -KILL "\${PPID}"
    exit 137
  fi
done
exec "${scheduler_clean_real_rm}" "\$@"
SH
      chmod +x "${scheduler_clean_bin}/rm"
      ;;
    before-receipt)
      cat > "${scheduler_clean_bin}/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\${arg}" == "${scheduler_clean_receipt}" ]]; then
    kill -KILL "\${PPID}"
    exit 137
  fi
done
exec "${scheduler_clean_real_rm}" "\$@"
SH
      chmod +x "${scheduler_clean_bin}/rm"
      ;;
  esac
  scheduler_clean_rc=0
  HOME="${scheduler_clean_home}" \
    PATH="${scheduler_clean_bin}:${PATH}" \
    VIBEGUARD_TEST_UNAME=Linux \
    bash "${REPO_DIR}/setup.sh" --clean >/dev/null 2>&1 \
    || scheduler_clean_rc=$?
  assert_cmd "scheduler clean crash ${scheduler_clean_point} exits nonzero" \
    test "${scheduler_clean_rc}" -ne 0
  assert_cmd "scheduler clean crash ${scheduler_clean_point} persists cleaning phase" \
    grep -qFx "phase=cleaning" "${scheduler_clean_receipt}"
  HOME="${scheduler_clean_home}" VIBEGUARD_TEST_UNAME=Linux \
    bash "${REPO_DIR}/setup.sh" --clean >/dev/null
  assert_cmd "scheduler clean retry ${scheduler_clean_point} removes all owned state" bash -c \
    'test ! -e "$1" && test ! -e "$2" && test ! -e "$3"' _ \
    "${scheduler_clean_service}" "${scheduler_clean_timer}" \
    "${scheduler_clean_receipt}"
done

cleaning_drift_home="${TMP_HOME}/scheduler-clean-drift-home"
cleaning_drift_timer="${cleaning_drift_home}/.config/systemd/user/vibeguard-gc.timer"
cleaning_drift_receipt="${cleaning_drift_home}/.vibeguard/scheduler-ownership"
mkdir -p "$(dirname "${cleaning_drift_timer}")" "$(dirname "${cleaning_drift_receipt}")"
printf '%s\n' '[Timer]' 'OnCalendar=daily' > "${cleaning_drift_timer}"
cleaning_drift_original_sha="$(
  shasum -a 256 "${cleaning_drift_timer}" | awk '{print $1}'
)"
printf 'schema=1\nkind=systemd\nphase=cleaning\nservice_sha256=%064d\ntimer_sha256=%s\n' \
  0 "${cleaning_drift_original_sha}" > "${cleaning_drift_receipt}"
printf 'Environment="CUSTOM_AFTER_CRASH=preserve"\n' >> "${cleaning_drift_timer}"
cleaning_drift_before="$(
  shasum -a 256 "${cleaning_drift_timer}" "${cleaning_drift_receipt}"
)"
cleaning_drift_rc=0
cleaning_drift_out="$(
  HOME="${cleaning_drift_home}" VIBEGUARD_TEST_UNAME=Linux \
    bash "${REPO_DIR}/setup.sh" --clean 2>&1
)" || cleaning_drift_rc=$?
assert_cmd "cleaning retry with drift exits nonzero" test "${cleaning_drift_rc}" -ne 0
assert_contains "${cleaning_drift_out}" \
  "scheduler ownership receipt does not match current systemd files" \
  "cleaning retry reports drift instead of deleting remaining state"
assert_cmd "cleaning retry preserves drifted file and receipt byte-for-byte" bash -c \
  'test "$(shasum -a 256 "$1" "$2")" = "$3"' _ \
  "${cleaning_drift_timer}" "${cleaning_drift_receipt}" \
  "${cleaning_drift_before}"

legacy_scheduler_home="${TMP_HOME}/legacy-systemd-scheduler-home"
legacy_scheduler_dir="${legacy_scheduler_home}/.config/systemd/user"
legacy_scheduler_service="${legacy_scheduler_dir}/vibeguard-gc.service"
legacy_scheduler_timer="${legacy_scheduler_dir}/vibeguard-gc.timer"
mkdir -p "${legacy_scheduler_dir}"
sed "s|__VIBEGUARD_DIR__|${REPO_DIR}|g" \
  "${REPO_DIR}/scripts/systemd/vibeguard-gc.service" > "${legacy_scheduler_service}"
cp "${REPO_DIR}/scripts/systemd/vibeguard-gc.timer" "${legacy_scheduler_timer}"
legacy_scheduler_out="$(
  HOME="${legacy_scheduler_home}" VIBEGUARD_TEST_UNAME=Linux \
    bash "${REPO_DIR}/setup.sh" --clean 2>&1
)"
assert_contains "${legacy_scheduler_out}" "Removed scheduled GC" \
  "clean recognizes and removes legacy VibeGuard scheduler files without a receipt"
assert_cmd "legacy scheduler cleanup removes units and temporary ownership receipt" bash -c \
  'test ! -e "$1" && test ! -e "$2" && test ! -e "$3"' _ \
  "${legacy_scheduler_service}" "${legacy_scheduler_timer}" \
  "${legacy_scheduler_home}/.vibeguard/scheduler-ownership"

unowned_scheduler_home="${TMP_HOME}/unowned-systemd-scheduler-home"
unowned_scheduler_dir="${unowned_scheduler_home}/.config/systemd/user"
mkdir -p "${unowned_scheduler_dir}"
printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/custom-gc' \
  > "${unowned_scheduler_dir}/vibeguard-gc.service"
printf '%s\n' '[Timer]' 'OnCalendar=daily' \
  > "${unowned_scheduler_dir}/vibeguard-gc.timer"
unowned_scheduler_before="$(
  shasum -a 256 "${unowned_scheduler_dir}/vibeguard-gc.service" \
    "${unowned_scheduler_dir}/vibeguard-gc.timer"
)"
unowned_scheduler_rc=0
HOME="${unowned_scheduler_home}" VIBEGUARD_TEST_UNAME=Linux \
  bash "${REPO_DIR}/setup.sh" --clean >/dev/null 2>&1 \
  || unowned_scheduler_rc=$?
assert_cmd "clean refuses scheduler files whose legacy VibeGuard ownership is unproven" \
  test "${unowned_scheduler_rc}" -ne 0
assert_cmd "unowned legacy scheduler files remain byte-for-byte" bash -c \
  'test "$(shasum -a 256 "$1" "$2")" = "$3"' _ \
  "${unowned_scheduler_dir}/vibeguard-gc.service" \
  "${unowned_scheduler_dir}/vibeguard-gc.timer" "${unowned_scheduler_before}"

for scheduler_edit_target in service timer; do
  scheduler_edit_home="${TMP_HOME}/scheduler-edit-${scheduler_edit_target}-home"
  scheduler_edit_bin="${TMP_HOME}/scheduler-edit-${scheduler_edit_target}-bin"
  scheduler_edit_service="${scheduler_edit_home}/.config/systemd/user/vibeguard-gc.service"
  scheduler_edit_timer="${scheduler_edit_home}/.config/systemd/user/vibeguard-gc.timer"
  scheduler_edit_receipt="${scheduler_edit_home}/.vibeguard/scheduler-ownership"
  mkdir -p "$(dirname "${scheduler_edit_service}")" \
    "$(dirname "${scheduler_edit_receipt}")" "${scheduler_edit_bin}"
  printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/managed-gc' \
    > "${scheduler_edit_service}"
  printf '%s\n' '[Timer]' 'OnCalendar=daily' > "${scheduler_edit_timer}"
  printf 'schema=1\nkind=systemd\nphase=managed\nservice_sha256=%s\ntimer_sha256=%s\n' \
    "$(shasum -a 256 "${scheduler_edit_service}" | awk '{print $1}')" \
    "$(shasum -a 256 "${scheduler_edit_timer}" | awk '{print $1}')" \
    > "${scheduler_edit_receipt}"
  if [[ "${scheduler_edit_target}" == "service" ]]; then
    scheduler_edit_path="${scheduler_edit_service}"
  else
    scheduler_edit_path="${scheduler_edit_timer}"
  fi
  cat > "${scheduler_edit_bin}/systemctl" <<SH
#!/usr/bin/env bash
[[ "\${1:-}" == "--user" ]] && shift
case "\${1:-}" in
  stop|daemon-reload) exit 0 ;;
  is-active) printf 'inactive\\n'; exit 3 ;;
  disable)
    printf 'USER_EDIT_DURING_DISABLE=preserve\\n' >> "${scheduler_edit_path}"
    exit 0
    ;;
  is-enabled) printf 'disabled\\n'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "${scheduler_edit_bin}/systemctl"
  scheduler_edit_rc=0
  scheduler_edit_out="$(
    HOME="${scheduler_edit_home}" \
      PATH="${scheduler_edit_bin}:${PATH}" \
      VIBEGUARD_TEST_UNAME=Linux \
      bash "${REPO_DIR}/setup.sh" --clean 2>&1
  )" || scheduler_edit_rc=$?
  assert_cmd "systemd ${scheduler_edit_target} edit during disable fails clean" \
    test "${scheduler_edit_rc}" -ne 0
  assert_contains "${scheduler_edit_out}" \
    "changed after scheduler deactivation; preserving file and cleaning receipt" \
    "systemd ${scheduler_edit_target} concurrent edit is explicit"
  assert_not_contains "${scheduler_edit_out}" "VibeGuard cleaned." \
    "systemd ${scheduler_edit_target} concurrent edit never reports clean complete"
  assert_cmd "systemd ${scheduler_edit_target} edit and cleaning receipt remain" bash -c \
    'grep -qF "USER_EDIT_DURING_DISABLE=preserve" "$1" && grep -qFx "phase=cleaning" "$2"' _ \
    "${scheduler_edit_path}" "${scheduler_edit_receipt}"
  if [[ "${scheduler_edit_target}" == "service" ]]; then
    assert_cmd "service drift stops before timer deletion" \
      test -f "${scheduler_edit_timer}"
  else
    assert_cmd "timer drift after service deletion preserves timer" bash -c \
      'test ! -e "$1" && test -f "$2"' _ \
      "${scheduler_edit_service}" "${scheduler_edit_timer}"
  fi
done

launchd_edit_home="${TMP_HOME}/scheduler-edit-launchd-home"
launchd_edit_bin="${TMP_HOME}/scheduler-edit-launchd-bin"
launchd_edit_plist="${launchd_edit_home}/Library/LaunchAgents/com.vibeguard.gc.plist"
launchd_edit_receipt="${launchd_edit_home}/.vibeguard/scheduler-ownership"
mkdir -p "$(dirname "${launchd_edit_plist}")" \
  "$(dirname "${launchd_edit_receipt}")" "${launchd_edit_bin}"
printf 'managed launchd scheduler\n' > "${launchd_edit_plist}"
printf 'schema=1\nkind=launchd\nphase=managed\nplist_sha256=%s\n' \
  "$(shasum -a 256 "${launchd_edit_plist}" | awk '{print $1}')" \
  > "${launchd_edit_receipt}"
launchd_edit_state="${launchd_edit_home}/.launchctl-vibeguard-loaded"
touch "${launchd_edit_state}"
cat > "${launchd_edit_bin}/launchctl" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  print) [[ -f "${launchd_edit_state}" ]] ;;
  bootout)
    printf 'USER_EDIT_DURING_BOOTOUT=preserve\\n' >> "${launchd_edit_plist}"
    rm -f "${launchd_edit_state}"
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "${launchd_edit_bin}/launchctl"
launchd_edit_rc=0
launchd_edit_out="$(
  HOME="${launchd_edit_home}" PATH="${launchd_edit_bin}:${PATH}" \
    VIBEGUARD_TEST_UNAME=Darwin \
    bash "${REPO_DIR}/setup.sh" --clean 2>&1
)" || launchd_edit_rc=$?
assert_cmd "launchd plist edit during bootout fails clean" \
  test "${launchd_edit_rc}" -ne 0
assert_contains "${launchd_edit_out}" \
  "changed after scheduler deactivation; preserving file and cleaning receipt" \
  "launchd concurrent edit is explicit"
assert_not_contains "${launchd_edit_out}" "VibeGuard cleaned." \
  "launchd concurrent edit never reports clean complete"
assert_cmd "launchd concurrent edit and cleaning receipt remain" bash -c \
  'grep -qF "USER_EDIT_DURING_BOOTOUT=preserve" "$1" && grep -qFx "phase=cleaning" "$2"' _ \
  "${launchd_edit_plist}" "${launchd_edit_receipt}"

launchd_fail_home="${TMP_HOME}/scheduler-deactivate-launchd-fail-home"
launchd_fail_bin="${TMP_HOME}/scheduler-deactivate-launchd-fail-bin"
launchd_fail_plist="${launchd_fail_home}/Library/LaunchAgents/com.vibeguard.gc.plist"
launchd_fail_receipt="${launchd_fail_home}/.vibeguard/scheduler-ownership"
launchd_fail_state="${launchd_fail_home}/.launchctl-vibeguard-loaded"
mkdir -p "$(dirname "${launchd_fail_plist}")" \
  "$(dirname "${launchd_fail_receipt}")" "${launchd_fail_bin}"
printf 'managed launchd scheduler\n' > "${launchd_fail_plist}"
printf 'schema=1\nkind=launchd\nphase=managed\nplist_sha256=%s\n' \
  "$(shasum -a 256 "${launchd_fail_plist}" | awk '{print $1}')" \
  > "${launchd_fail_receipt}"
touch "${launchd_fail_state}"
cat > "${launchd_fail_bin}/launchctl" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  print) [[ -f "${launchd_fail_state}" ]] ;;
  bootout) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "${launchd_fail_bin}/launchctl"
launchd_fail_rc=0
launchd_fail_out="$(
  HOME="${launchd_fail_home}" PATH="${launchd_fail_bin}:${PATH}" \
    VIBEGUARD_TEST_UNAME=Darwin \
    bash "${REPO_DIR}/setup.sh" --clean 2>&1
)" || launchd_fail_rc=$?
assert_cmd "launchd bootout failure fails clean" test "${launchd_fail_rc}" -ne 0
assert_contains "${launchd_fail_out}" "failed to deactivate scheduled GC launchd job" \
  "launchd bootout failure is explicit"
assert_not_contains "${launchd_fail_out}" "VibeGuard cleaned." \
  "launchd bootout failure never reports clean complete"
assert_cmd "launchd bootout failure preserves plist, receipt, and loaded state" bash -c \
  'test -f "$1" && grep -qFx "phase=cleaning" "$2" && test -f "$3"' _ \
  "${launchd_fail_plist}" "${launchd_fail_receipt}" "${launchd_fail_state}"

launchd_clean_home="${TMP_HOME}/scheduler-clean-launchd-home"
launchd_clean_bin="${TMP_HOME}/scheduler-clean-launchd-bin"
launchd_clean_plist="${launchd_clean_home}/Library/LaunchAgents/com.vibeguard.gc.plist"
launchd_clean_receipt="${launchd_clean_home}/.vibeguard/scheduler-ownership"
mkdir -p "$(dirname "${launchd_clean_plist}")" \
  "$(dirname "${launchd_clean_receipt}")" "${launchd_clean_bin}"
printf 'managed launchd scheduler\n' > "${launchd_clean_plist}"
printf 'schema=1\nkind=launchd\nplist_sha256=%s\n' \
  "$(shasum -a 256 "${launchd_clean_plist}" | awk '{print $1}')" \
  > "${launchd_clean_receipt}"
launchd_clean_real_rm="$(command -v rm)"
cat > "${launchd_clean_bin}/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\${arg}" == "${launchd_clean_plist}" ]]; then
    "${launchd_clean_real_rm}" -f -- "${launchd_clean_plist}"
    kill -KILL "\${PPID}"
    exit 137
  fi
done
exec "${launchd_clean_real_rm}" "\$@"
SH
chmod +x "${launchd_clean_bin}/rm"
launchd_clean_rc=0
HOME="${launchd_clean_home}" PATH="${launchd_clean_bin}:${PATH}" \
  VIBEGUARD_TEST_UNAME=Darwin \
  bash "${REPO_DIR}/setup.sh" --clean >/dev/null 2>&1 \
  || launchd_clean_rc=$?
assert_cmd "launchd clean crash after owned file deletion exits nonzero" \
  test "${launchd_clean_rc}" -ne 0
assert_cmd "launchd clean crash preserves cleaning receipt" \
  grep -qFx "phase=cleaning" "${launchd_clean_receipt}"
HOME="${launchd_clean_home}" VIBEGUARD_TEST_UNAME=Darwin \
  bash "${REPO_DIR}/setup.sh" --clean >/dev/null
assert_cmd "launchd clean retry removes receipt after confirming absence" bash -c \
  'test ! -e "$1" && test ! -e "$2"' _ \
  "${launchd_clean_plist}" "${launchd_clean_receipt}"

source "${REPO_DIR}/tests/setup/cleanup_failure_tests.sh"

bash "${REPO_DIR}/setup.sh" --yes --profile full >/dev/null

_CUSTOM_RULE="${HOME}/.claude/rules/vibeguard/common/security.md"
rm -f "${_CUSTOM_RULE}"
printf 'local custom security rule\n' > "${_CUSTOM_RULE}"
rule_protect_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile full 2>&1 || true)"
assert_contains "${rule_protect_out}" "refusing to overwrite modified local rule file" "setup refuses to overwrite modified local rule copies"
assert_cmd "modified local rule copy remains a regular file" bash -c "[ -f '${_CUSTOM_RULE}' ] && [ ! -L '${_CUSTOM_RULE}' ]"
rule_force_out="$(bash "${REPO_DIR}/setup.sh" --yes --profile full --force-overwrite 2>&1)"
assert_contains "${rule_force_out}" "FORCE: replacing local rule copy" "--force-overwrite reports local rule replacement"
assert_cmd "--force-overwrite restores rule symlink" test -L "${_CUSTOM_RULE}"

header "codex config helper failure propagates"
_FAILING_CODEX_CONFIG_RUNTIME="${TMP_HOME}/failing-codex-config-runtime"
cat > "${_FAILING_CODEX_CONFIG_RUNTIME}" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "setup-codex-config-enable-hooks" ]]; then
  exit 42
fi
exec "${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime" "\$@"
EOF
chmod +x "${_FAILING_CODEX_CONFIG_RUNTIME}"
fail_install_out="$(VIBEGUARD_SETUP_RUNTIME="${_FAILING_CODEX_CONFIG_RUNTIME}" bash "${REPO_DIR}/setup.sh" --yes 2>&1 || true)"
assert_contains "${fail_install_out}" "Failed to enable hooks feature in config.toml" "setup reports hooks helper failure"
assert_cmd "setup exits before reporting success when hooks helper fails" bash -c "! grep -q 'Setup complete! All components installed.' <<< '${fail_install_out}'"

header "setup --check rejects invalid codex config"
_VALID_CODEX_CONFIG="${TMP_HOME}/config.toml.valid.backup"
cp "${HOME}/.codex/config.toml" "${_VALID_CODEX_CONFIG}"
cat > "${HOME}/.codex/config.toml" <<'TOML'
not valid toml =
[features]
hooks = true
TOML
invalid_codex_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_CONFIG}" "${HOME}/.codex/config.toml"
assert_contains "${invalid_codex_check_out}" "[BROKEN] ~/.codex/config.toml is malformed TOML" "--check reports invalid ~/.codex/config.toml"
assert_cmd "invalid config does not report hooks enabled" bash -c "! grep -qF '[OK] hooks feature enabled in config.toml' <<< '${invalid_codex_check_out}'"

header "setup --check rejects invalid UTF-8 codex config"
python3 - <<'PY' "${HOME}/.codex/config.toml"
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'[features]\nhooks = true\n\xff')
PY
invalid_utf8_codex_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_CONFIG}" "${HOME}/.codex/config.toml"
assert_contains "${invalid_utf8_codex_check_out}" "[BROKEN] ~/.codex/config.toml is malformed TOML" "--check reports invalid UTF-8 ~/.codex/config.toml"
assert_cmd "invalid UTF-8 config does not report hooks enabled" bash -c "! grep -qF '[OK] hooks feature enabled in config.toml' <<< '${invalid_utf8_codex_check_out}'"

header "setup --check validates codex AGENTS"
_VALID_CODEX_AGENTS="${TMP_HOME}/AGENTS.md.valid.backup"
cp "${HOME}/.codex/AGENTS.md" "${_VALID_CODEX_AGENTS}"
: > "${HOME}/.codex/AGENTS.md"
zero_byte_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${zero_byte_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md is 0 bytes" "--check reports 0-byte ~/.codex/AGENTS.md"
python3 - <<'PY' "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("<!-- vibeguard-end -->", "", 1), encoding="utf-8")
PY
missing_end_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${missing_end_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md marker mismatch" "--check reports missing Codex AGENTS end marker"
printf '<!-- vibeguard-start -->\n' >> "${HOME}/.codex/AGENTS.md"
duplicate_start_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_not_contains "${duplicate_start_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md marker mismatch" "--check does not treat an unmanaged extra start marker as a managed-block mismatch"
assert_contains "${duplicate_start_agents_check_out}" "[WARN] ~/.codex/AGENTS.md has" "--check warns about unmanaged extra start marker outside the valid block"
python3 - <<'PY' "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text + "\n" + text, encoding="utf-8")
PY
duplicate_valid_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${duplicate_valid_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md marker mismatch" "--check reports duplicate valid Codex AGENTS managed blocks"
python3 - <<'PY' "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("| SEC-13 |", "| SEC-X |", 1), encoding="utf-8")
PY
missing_anchor_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${missing_anchor_agents_check_out}" "[BROKEN] ~/.codex/AGENTS.md missing required anchors" "--check reports missing Codex AGENTS required anchors"
python3 - <<'PY' "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
updated, count = re.subn(r"\b[0-9]+ rules total\b", "999 rules total", text, count=1)
if count != 1:
    raise SystemExit(1)
path.write_text(updated, encoding="utf-8")
PY
stale_banner_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${stale_banner_agents_check_out}" "~/.codex/AGENTS.md declares 999 rules" "--check reports stale Codex AGENTS rule banner"
printf '# malicious injection appended by something\n' >> "${HOME}/.codex/AGENTS.md"
external_agents_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${external_agents_check_out}" "[WARN] ~/.codex/AGENTS.md has 1 non-empty unmanaged line(s) outside VibeGuard block" "--check warns on unmanaged Codex AGENTS content"
assert_contains "${external_agents_check_out}" "Codex native hooks: PreToolUse(Bash/Edit/Write via apply_patch), PermissionRequest(Bash/Edit/Write via apply_patch), PostToolUse(Bash/Edit/Write via apply_patch); full/strict add Stop(stop-guard/learn-evaluator)" "--check reports profile-selected Codex native hook scope"

header "setup --check uses managed rule count banners"
_VALID_CLAUDE_MD="${TMP_HOME}/CLAUDE.md.valid.backup"
cp "${HOME}/.claude/CLAUDE.md" "${_VALID_CLAUDE_MD}"
python3 - <<'PY' "${HOME}/.claude/CLAUDE.md"
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text("Personal note: 5 rules I keep locally.\n" + text, encoding="utf-8")
PY
external_rule_count_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
cp "${_VALID_CLAUDE_MD}" "${HOME}/.claude/CLAUDE.md"
assert_contains "${external_rule_count_check_out}" "[OK] Rule count in sync:" "--check ignores unmanaged Claude rule count text"
assert_not_contains "${external_rule_count_check_out}" "CLAUDE.md declares 5 rules" "--check does not read rule count outside the VibeGuard Claude block"
python3 - <<'PY' "${HOME}/.claude/CLAUDE.md" "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import sys

for arg in sys.argv[1:]:
    path = Path(arg)
    text = path.read_text(encoding="utf-8")
    updated = text.replace(
        "Compact Chat Contract: progress updates, concise answers, plain formatting.",
        "Compact Chat Contract: progress updates, concise answers, ornate formatting.",
        1,
    )
    if updated == text:
        raise SystemExit(1)
    path.write_text(updated, encoding="utf-8")
PY
semantic_block_check_out="$(bash "${REPO_DIR}/setup.sh" --check)"
semantic_block_strict_rc=0
semantic_block_strict_out="$(bash "${REPO_DIR}/setup.sh" --check --strict 2>&1)" || semantic_block_strict_rc=$?
cp "${_VALID_CLAUDE_MD}" "${HOME}/.claude/CLAUDE.md"
cp "${_VALID_CODEX_AGENTS}" "${HOME}/.codex/AGENTS.md"
assert_contains "${semantic_block_check_out}" "[DRIFT] CLAUDE.md managed VibeGuard block differs from current rules" "--check reports semantic drift in CLAUDE.md managed block"
assert_contains "${semantic_block_check_out}" "[DRIFT] ~/.codex/AGENTS.md managed VibeGuard block differs from current rules" "--check reports semantic drift in Codex AGENTS managed block"
assert_contains "${semantic_block_strict_out}" "[DRIFT] CLAUDE.md managed VibeGuard block differs from current rules" "--check --strict reports managed block drift"
assert_cmd "--check --strict exits broken for managed block drift" test "${semantic_block_strict_rc}" -eq 2

header "setup --check stays read-only"
python3 - <<'PY' "${HOME}/.claude/CLAUDE.md"
from pathlib import Path
import re
path = Path(__import__('sys').argv[1])
text = path.read_text(encoding='utf-8')
updated = re.sub(r'\b\d+ rules\b', '999 rules', text, count=1)
path.write_text(updated, encoding='utf-8')
PY
python3 - <<'PY' "${HOME}/.codex/AGENTS.md"
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
updated, count = re.subn(r"\b[0-9]+ rules total\b", "999 rules total", text, count=1)
if count != 1:
    raise SystemExit(1)
path.write_text(updated, encoding="utf-8")
PY
before_sha="$(shasum -a 256 "${HOME}/.claude/CLAUDE.md" | cut -d' ' -f1)"
agents_before_sha="$(shasum -a 256 "${HOME}/.codex/AGENTS.md" | cut -d' ' -f1)"
check_again_out="$(bash "${REPO_DIR}/setup.sh" --check)"
after_sha="$(shasum -a 256 "${HOME}/.claude/CLAUDE.md" | cut -d' ' -f1)"
agents_after_sha="$(shasum -a 256 "${HOME}/.codex/AGENTS.md" | cut -d' ' -f1)"
assert_contains "${check_again_out}" "CLAUDE.md declares 999 rules" "--check reports CLAUDE.md drift"
assert_contains "${check_again_out}" "~/.codex/AGENTS.md declares 999 rules" "--check reports Codex AGENTS.md drift"
assert_contains "${check_again_out}" "[OK] vibeguard-runtime runtime binary installed" "--check reports vibeguard-runtime installed"
assert_cmd "--check does not rewrite ~/.claude/CLAUDE.md" test "${before_sha}" = "${after_sha}"
assert_cmd "--check does not rewrite ~/.codex/AGENTS.md" test "${agents_before_sha}" = "${agents_after_sha}"
assert_cmd "--check does not drop or duplicate the chat contract block" python3 -c "from pathlib import Path; text = Path('${HOME}/.claude/CLAUDE.md').read_text(encoding='utf-8'); raise SystemExit(0 if text.count('${CHAT_CONTRACT_ANCHOR}') == 1 else 1)"
repair_out="$(bash "${REPO_DIR}/setup.sh" --yes)"
assert_contains "${repair_out}" "Setup complete! All components installed." "re-running setup after drift still succeeds"
assert_cmd "repair restores CLAUDE.md rule banner count" assert_claude_rule_banner_matches_expected_rules
assert_cmd "repair restores Codex AGENTS.md rule banner count" assert_codex_rule_banner_matches_expected_rules
assert_cmd "repeat setup keeps exactly one chat contract block" python3 -c "from pathlib import Path; text = Path('${HOME}/.claude/CLAUDE.md').read_text(encoding='utf-8'); raise SystemExit(0 if text.count('${CHAT_CONTRACT_ANCHOR}') == 1 else 1)"

header "upsert idempotency with non-standard wrapper path"
# Run upsert twice with a wrapper path that does not contain 'run-hook-codex.sh'.
# Without the _has_entry dedup fix, the second upsert would append duplicates.
_IDEMPOTENT_HOOKS="${TMP_HOME}/.codex/hooks-idempotent.json"
_IDEMPOTENT_WRAPPER="${TMP_HOME}/test/wrapper.sh"
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}" >/dev/null
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}" >/dev/null
assert_cmd "double-upsert with non-standard wrapper produces exactly 4 Stop entries (not 8)" python3 -c "
import json
data = json.load(open('${_IDEMPOTENT_HOOKS}'))
stop_entries = data.get('hooks', {}).get('Stop', [])
raise SystemExit(0 if len(stop_entries) == 2 else 1)
"
assert_cmd "double-upsert with non-standard wrapper: check-vibeguard passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}" --wrapper "${_IDEMPOTENT_WRAPPER}"

header "remove-vibeguard cleans custom-wrapper-path hooks"
# Issue fix: _is_vibeguard_command must recognise vibeguard-* scripts even when
# the wrapper path does not contain 'run-hook-codex.sh'.
python3 "${CODEX_HOOKS_HELPER}" remove-vibeguard --hooks-file "${_IDEMPOTENT_HOOKS}"
assert_cmd "remove-vibeguard removes custom-wrapper vibeguard hooks" bash -c "! grep -q 'vibeguard-pre-bash-guard.sh' '${_IDEMPOTENT_HOOKS}'"
assert_cmd "remove-vibeguard removes all managed hook scripts" bash -c "! grep -qE 'vibeguard-(pre-bash-guard|pre-edit-guard|pre-write-guard|post-edit-guard|post-write-guard|post-build-check|stop-guard|learn-evaluator)\\.sh' '${_IDEMPOTENT_HOOKS}'"

header "_has_entry validates type and timeout (Issue 2 guard)"
# A stale entry that has the correct command but is missing 'type: command' or
# has a spurious timeout must NOT satisfy check-vibeguard (silent false positive).
_STALE_HOOKS="${TMP_HOME}/.codex/hooks-stale.json"
_STALE_WRAPPER="${TMP_HOME}/test/stale-wrapper.sh"
# Write an entry with correct command but no 'type' field and no 'timeout'.
python3 -c "
import json, sys
data = {
  'hooks': {
    'PreToolUse': [{
      'matcher': 'Bash',
      'hooks': [{'command': 'bash ${_STALE_WRAPPER} vibeguard-pre-bash-guard.sh'}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects stale entry missing type field" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# After upsert the entry must be repaired and check must pass.
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}" >/dev/null
assert_cmd "upsert repairs stale entry; check-vibeguard then passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}"
# Write a Stop entry with correct command but the wrong timeout.
python3 -c "
import json
data = {
  'hooks': {
    'Stop': [{
      'hooks': [{'type': 'command', 'command': 'bash ${_STALE_WRAPPER} vibeguard-stop-guard.sh', 'timeout': 99}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects Stop entry with wrong timeout" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# Write a Stop entry with correct command+type but a spurious matcher (Stop spec has none).
python3 -c "
import json
data = {
  'hooks': {
    'Stop': [{
      'matcher': 'Bash',
      'hooks': [{'type': 'command', 'command': 'bash ${_STALE_WRAPPER} vibeguard-stop-guard.sh'}]
    }]
  }
}
with open('${_STALE_HOOKS}', 'w') as f:
    json.dump(data, f, indent=2)
"
assert_cmd "check-vibeguard rejects Stop entry with spurious matcher" bash -c "! python3 '${CODEX_HOOKS_HELPER}' check-vibeguard --hooks-file '${_STALE_HOOKS}' --wrapper '${_STALE_WRAPPER}'"
# After upsert the entry must be repaired and check must pass.
python3 "${CODEX_HOOKS_HELPER}" upsert-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}" >/dev/null
assert_cmd "upsert repairs Stop entry with spurious matcher; check-vibeguard then passes" python3 "${CODEX_HOOKS_HELPER}" check-vibeguard --hooks-file "${_STALE_HOOKS}" --wrapper "${_STALE_WRAPPER}"
