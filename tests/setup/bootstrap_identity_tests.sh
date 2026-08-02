header "bootstrap process birth identity"

assert_cmd "strong identity recognizes Linux boot and start tokens" bash -c '
  source "$1"
  bootstrap_process_identity_is_strong \
    linux-v1:12345678-1234-1234-1234-123456789abc:424242
' _ "${BOOTSTRAP_LIB}"
assert_cmd "strong identity recognizes Darwin microsecond birth tokens" bash -c '
  source "$1"
  bootstrap_process_identity_is_strong darwin-v1:1700000000:000123
' _ "${BOOTSTRAP_LIB}"
assert_cmd "second-resolution legacy identity is not strong" bash -c '
  source "$1"
  ! bootstrap_process_identity_is_strong Thu_Jan_1_00:00:00_1970
' _ "${BOOTSTRAP_LIB}"

linux_boot_id="12345678-1234-1234-1234-123456789abc"
linux_stat_record="77 (name with ) embedded spaces) S 1 77 77 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 424242 0 0"
assert_cmd "Linux stat parser handles spaces and right parentheses in comm" bash -c '
  source "$1"
  bootstrap_linux_process_snapshot_from_records 77 "$2" "$3"
  test "${BOOTSTRAP_PROCESS_PGID}" = 77
  test "${BOOTSTRAP_PROCESS_STATE}" = S
  test "${BOOTSTRAP_PROCESS_IDENTITY}" = "linux-v1:${3}:424242"
  test "${BOOTSTRAP_PROCESS_IDENTITY_STRENGTH}" = strong
' _ "${BOOTSTRAP_LIB}" "${linux_stat_record}" "${linux_boot_id}"
assert_cmd "Linux start ticks distinguish same-second PID reuse" bash -c '
  source "$1"
  bootstrap_linux_process_snapshot_from_records 77 "$2" "$3"
  first="${BOOTSTRAP_PROCESS_IDENTITY}"
  bootstrap_linux_process_snapshot_from_records 77 "${2/424242/424243}" "$3"
  test "${BOOTSTRAP_PROCESS_IDENTITY}" != "${first}"
' _ "${BOOTSTRAP_LIB}" "${linux_stat_record}" "${linux_boot_id}"
assert_cmd "Linux boot identity distinguishes equal ticks after reboot" bash -c '
  source "$1"
  bootstrap_linux_process_snapshot_from_records 77 "$2" "$3"
  first="${BOOTSTRAP_PROCESS_IDENTITY}"
  bootstrap_linux_process_snapshot_from_records 77 "$2" \
    abcdefab-cdef-abcd-efab-cdefabcdefab
  test "${BOOTSTRAP_PROCESS_IDENTITY}" != "${first}"
' _ "${BOOTSTRAP_LIB}" "${linux_stat_record}" "${linux_boot_id}"
assert_cmd "Linux snapshot rejects truncated stat records" bash -c '
  source "$1"
  ! bootstrap_linux_process_snapshot_from_records 77 "77 (short) S 1 77" "$2"
' _ "${BOOTSTRAP_LIB}" "${linux_boot_id}"
if [[ "$(uname -s)" == "Linux" ]]; then
  assert_cmd "Linux process identity does not depend on ps availability" bash -c '
    source "$1"
    ps() { return 99; }
    bootstrap_process_snapshot $$
    test "${BOOTSTRAP_PROCESS_IDENTITY_STRENGTH}" = strong
    [[ "${BOOTSTRAP_PROCESS_IDENTITY}" =~ ^linux-v1:[0-9a-f-]+:[0-9]+$ ]]
  ' _ "${BOOTSTRAP_LIB}"
fi

assert_cmd "Darwin snapshot preserves microsecond birth precision" bash -c '
  source "$1"
  bootstrap_darwin_process_snapshot_from_output 77 "$2"
  test "${BOOTSTRAP_PROCESS_PGID}" = 77
  test "${BOOTSTRAP_PROCESS_STATE}" = S
  test "${BOOTSTRAP_PROCESS_IDENTITY}" = darwin-v1:1700000000:000123
' _ "${BOOTSTRAP_LIB}" $'77\t77\t2\t1700000000\t123'
for invalid_darwin_snapshot in \
  $'77\t77\t2\t1700000000' \
  $'78\t77\t2\t1700000000\t123' \
  $'77\t77\t6\t1700000000\t123' \
  $'77\t77\t2\t1700000000\t1000000'; do
  assert_cmd "Darwin snapshot rejects malformed or mismatched birth evidence" bash -c '
    source "$1"
    ! bootstrap_darwin_process_snapshot_from_output 77 "$2"
  ' _ "${BOOTSTRAP_LIB}" "${invalid_darwin_snapshot}"
done

assert_cmd "strong identity mismatch classifies the original process as dead" bash -c '
  source "$1"
  bootstrap_pid_liveness() { BOOTSTRAP_PID_LIVENESS=active; }
  bootstrap_process_snapshot() {
    BOOTSTRAP_PROCESS_PGID=77 BOOTSTRAP_PROCESS_STATE=S
    BOOTSTRAP_PROCESS_IDENTITY=darwin-v1:1700000000:000124
    BOOTSTRAP_PROCESS_IDENTITY_STRENGTH=strong
  }
  bootstrap_process_identity_liveness 77 darwin-v1:1700000000:000123
  test "${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}" = dead
' _ "${BOOTSTRAP_LIB}"
assert_cmd "legacy live identity remains ambiguous instead of proving ownership" bash -c '
  source "$1"
  bootstrap_pid_liveness() { BOOTSTRAP_PID_LIVENESS=active; }
  bootstrap_process_snapshot() { return 99; }
  bootstrap_process_identity_liveness 77 Thu_Jan_1_00:00:00_1970
  test "${BOOTSTRAP_PROCESS_IDENTITY_LIVENESS}" = ambiguous
' _ "${BOOTSTRAP_LIB}"

if [[ "$(uname -s)" == "Darwin" ]]; then
  assert_cmd "Darwin proc_pidinfo snapshot yields a strong token under Bash 3.2" \
    /bin/bash -c '
      set -euo pipefail
      source "$1"
      bootstrap_process_snapshot $$
      test "${BOOTSTRAP_PROCESS_IDENTITY_STRENGTH}" = strong
      bootstrap_process_identity_is_strong "${BOOTSTRAP_PROCESS_IDENTITY}"
    ' _ "${BOOTSTRAP_LIB}"
fi

identity_uname_bin="${TMP_HOME}/bootstrap-identity-uname-bin"
mkdir -p "${identity_uname_bin}"
cat > "${identity_uname_bin}/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' FakeKernel
SH
chmod +x "${identity_uname_bin}/uname"
assert_cmd "birth identity bypasses PATH uname stubs and reads the real kernel" \
  env PATH="${identity_uname_bin}:${PATH}" REPO_DIR="${REPO_DIR}" bash -c '
    set -euo pipefail
    source "${REPO_DIR}/scripts/setup/bootstrap-lib.sh"
    bootstrap_process_snapshot $$
    case "$(command -p uname -s)" in
      Darwin) [[ "${BOOTSTRAP_PROCESS_IDENTITY}" == darwin-v1:* ]] ;;
      Linux) [[ "${BOOTSTRAP_PROCESS_IDENTITY}" == linux-v1:* ]] ;;
      *) exit 1 ;;
    esac
  '
