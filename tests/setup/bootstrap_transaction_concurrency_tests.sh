lock_wait_release="${TMP_HOME}/bootstrap-release-lock-wait"
lock_wait_home="${TMP_HOME}/bootstrap-lock-wait-home"
lock_wait_ready="${TMP_HOME}/bootstrap-lock-wait.ready"
lock_wait_fifo="${TMP_HOME}/bootstrap-lock-wait.fifo"
lock_wait_first_out="${TMP_HOME}/bootstrap-lock-wait-first.out"
lock_wait_first_download="${TMP_HOME}/bootstrap-lock-wait-first-download.log"
lock_wait_second_download="${TMP_HOME}/bootstrap-lock-wait-second-download.log"
make_hostile_bootstrap_release "${lock_wait_release}" "wait"
mkdir -p "${lock_wait_home}"
mkfifo "${lock_wait_fifo}"
: > "${lock_wait_first_download}"
: > "${lock_wait_second_download}"
env "${bootstrap_base_env[@]}" \
  HOME="${lock_wait_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  VIBEGUARD_TEST_DOWNLOAD_LOG="${lock_wait_first_download}" \
  VIBEGUARD_TEST_SETUP_READY="${lock_wait_ready}" \
  VIBEGUARD_TEST_SETUP_CONTINUE_FIFO="${lock_wait_fifo}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${lock_wait_first_out}" 2>&1 &
lock_wait_first_pid=$!
for _lock_wait_attempt in {1..100}; do
  [[ -e "${lock_wait_ready}" ]] && break
  sleep 0.05
done
assert_cmd "first bootstrap reaches setup handshake while owning the lock" \
  test -e "${lock_wait_ready}"
lock_wait_second_rc=0
lock_wait_second_out="$(
  env "${bootstrap_base_env[@]}" \
    HOME="${lock_wait_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
    VIBEGUARD_TEST_DOWNLOAD_LOG="${lock_wait_second_download}" \
    bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes 2>&1
)" || lock_wait_second_rc=$?
assert_cmd "concurrent bootstrap is rejected while first setup is running" \
  test "${lock_wait_second_rc}" -eq 73
assert_contains "${lock_wait_second_out}" "active bootstrap owner pid=" \
  "concurrent rejection identifies active bootstrap ownership"
assert_cmd "rejected concurrent bootstrap performs no download" \
  test ! -s "${lock_wait_second_download}"
printf 'continue\n' > "${lock_wait_fifo}"
lock_wait_first_rc=0
wait "${lock_wait_first_pid}" || lock_wait_first_rc=$?
assert_cmd "first bootstrap completes after deterministic setup handshake" \
  test "${lock_wait_first_rc}" -eq 0
assert_cmd "first bootstrap releases lock only after setup completes" \
  test ! -e "${lock_wait_home}/.vibeguard/dist/.bootstrap.lock"
assert_contains "$(cat "${lock_wait_first_out}")" "WAIT_SETUP_SUCCEEDED" \
  "first setup consumed the continuation handshake"

interactive_release="${TMP_HOME}/bootstrap-release-interactive"
interactive_home="${TMP_HOME}/bootstrap-interactive-home"
interactive_out="${TMP_HOME}/bootstrap-interactive.out"
make_hostile_bootstrap_release "${interactive_release}" interactive
mkdir -p "${interactive_home}"
interactive_rc=0
env "${bootstrap_base_env[@]}" HOME="${interactive_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${interactive_release}" \
  python3 - "${BOOTSTRAP}" "${BOOTSTRAP_VERSION}" "${interactive_out}" <<'PY' \
  || interactive_rc=$?
import errno
import os
import pty
import select
import signal
import sys
import time

bootstrap, version, output_path = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("bash", ["bash", bootstrap, "--version", version, "--", "--yes"], os.environ)
data = bytearray()
sent = False
status = None
deadline = time.monotonic() + 10
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                chunk = b""
            data.extend(chunk)
            if not sent and b"INTERACTIVE_READY" in data:
                os.write(fd, b"confirmed\n")
                sent = True
        waited, candidate = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            status = candidate
            break
finally:
    if status is None:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _, status = os.waitpid(pid, 0)
    os.close(fd)
    with open(output_path, "wb") as output:
        output.write(data)
if not sent or not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    raise SystemExit(1)
PY
assert_cmd "interactive bootstrap keeps isolated setup in the terminal foreground" \
  test "${interactive_rc}" -eq 0
assert_contains "$(cat "${interactive_out}")" "INTERACTIVE_SETUP_SUCCEEDED" \
  "interactive setup reads and validates terminal input"

interactive_ignore_release="${TMP_HOME}/bootstrap-release-interactive-ignore"
make_hostile_bootstrap_release "${interactive_ignore_release}" interactive-signal-ignore
for interactive_ignore_case in default_ready system_ready system_early system_stop; do
case "${interactive_ignore_case}" in
  default_ready)
    interactive_ignore_bash="$(command -v bash)"
    interactive_ignore_cancel_mode=ready
    interactive_ignore_expected=130
    ;;
  system_ready)
    interactive_ignore_bash="/bin/bash"
    interactive_ignore_cancel_mode=ready
    interactive_ignore_expected=130
    ;;
  system_early)
    interactive_ignore_bash="/bin/bash"
    interactive_ignore_cancel_mode=early
    interactive_ignore_expected=130
    ;;
  system_stop)
    interactive_ignore_bash="/bin/bash"
    interactive_ignore_cancel_mode=stop
    interactive_ignore_expected=148
    ;;
esac
interactive_ignore_home="${TMP_HOME}/bootstrap-interactive-ignore-${interactive_ignore_case}-home"
interactive_ignore_out="${TMP_HOME}/bootstrap-interactive-ignore-${interactive_ignore_case}.out"
mkdir -p "${interactive_ignore_home}"
interactive_ignore_rc=0
env "${bootstrap_base_env[@]}" HOME="${interactive_ignore_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${interactive_ignore_release}" \
  VIBEGUARD_TEST_BOOTSTRAP_BASH="${interactive_ignore_bash}" \
  VIBEGUARD_TEST_CANCEL_MODE="${interactive_ignore_cancel_mode}" \
  python3 - "${BOOTSTRAP}" "${BOOTSTRAP_VERSION}" "${interactive_ignore_out}" <<'PY' \
  || interactive_ignore_rc=$?
import errno
import os
import pty
import re
import select
import signal
import sys
import time

bootstrap, version, output_path = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    shell = os.environ["VIBEGUARD_TEST_BOOTSTRAP_BASH"]
    os.execve(shell, [shell, bootstrap, "--version", version, "--", "--yes"], os.environ)
data = bytearray()
sent = False
status = None
cancel_pgid = 0
cancel_mode = os.environ["VIBEGUARD_TEST_CANCEL_MODE"]
deadline = time.monotonic() + (20 if cancel_mode == "stop" else 10)
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.05)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                chunk = b""
            data.extend(chunk)
            try:
                foreground_pgid = os.tcgetpgrp(fd)
            except OSError:
                foreground_pgid = 0
            if (not sent and cancel_mode == "early" and foreground_pgid > 0
                    and foreground_pgid != pid):
                cancel_pgid = foreground_pgid
                os.write(fd, b"\x03")
                sent = True
            elif (not sent and cancel_mode in ("ready", "stop")
                    and b"INTERACTIVE_IGNORE_READY" in data):
                cancel_pgid = foreground_pgid
                os.write(fd, b"\x1a" if cancel_mode == "stop" else b"\x03")
                sent = True
        waited, candidate = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            status = candidate
            break
finally:
    match = re.search(rb"INTERACTIVE_IGNORE_READY pid=(\d+) pgid=(\d+) tpgid=(\d+)", data)
    if match is not None:
        setup_pid = int(match.group(1))
        setup_pgid = int(match.group(2))
        try:
            if os.getpgid(setup_pid) == setup_pgid:
                os.killpg(setup_pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if status is None:
        try:
            foreground_pgid = os.tcgetpgrp(fd)
        except OSError:
            foreground_pgid = 0
        if foreground_pgid > 0:
            try:
                os.killpg(foreground_pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if match is not None:
            try:
                os.killpg(int(match.group(2)), signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _, status = os.waitpid(pid, 0)
    os.close(fd)
    with open(output_path, "wb") as output:
        output.write(data)
match = re.search(rb"INTERACTIVE_IGNORE_READY pid=(\d+) pgid=(\d+) tpgid=(\d+)", data)
if match is not None:
    recorded_pid = match.group(1).decode()
    recorded_pgid = match.group(2).decode()
elif cancel_pgid > 0:
    recorded_pid = "99999998"
    recorded_pgid = str(cancel_pgid)
else:
    recorded_pid = "99999998"
    recorded_pgid = "99999999"
with open(output_path + ".pids", "w", encoding="ascii") as output:
    output.write(f"{recorded_pid} {recorded_pgid}\n")
if (not sent or not os.WIFEXITED(status)
        or (cancel_mode != "early" and match is None)):
    raise SystemExit(1)
raise SystemExit(os.WEXITSTATUS(status))
PY
assert_cmd "${interactive_ignore_case} Bash TTY control signal remains supervised" \
  test "${interactive_ignore_rc}" -eq "${interactive_ignore_expected}"
assert_contains "$(cat "${interactive_ignore_out}")" "escalating to KILL" \
  "${interactive_ignore_case} Bash TTY control uses bounded group-wide KILL escalation"
interactive_ignore_pid=99999998 interactive_ignore_pgid=99999999
if [[ -f "${interactive_ignore_out}.pids" ]]; then
  read -r interactive_ignore_pid interactive_ignore_pgid \
    < "${interactive_ignore_out}.pids"
fi
assert_cmd "TTY cancellation reaps the ignored setup group and releases ownership" bash -c '
  ! kill -0 "$1" 2>/dev/null
  ! "$2" -A -o pgid= -o stat= | awk -v expected="$3" \
    '\''$1 == expected && $2 !~ /^Z/ { live = 1 } END { exit live }'\''
  test ! -e "$4"
  test -z "$(find "$5" -maxdepth 1 -name ".bootstrap.lock.lease.*" -print -quit)"
' _ "${interactive_ignore_pid}" "$(command -v ps)" "${interactive_ignore_pgid}" \
  "${interactive_ignore_home}/.vibeguard/dist/.bootstrap.lock" \
  "${interactive_ignore_home}/.vibeguard/dist"
done

signal_release="${TMP_HOME}/bootstrap-release-signal-wait"
make_hostile_bootstrap_release "${signal_release}" signal-wait
for cancel_signal in INT TERM HUP; do
  case "${cancel_signal}" in
    INT) cancel_status=130 ;;
    TERM) cancel_status=143 ;;
    HUP) cancel_status=129 ;;
  esac
  signal_home="${TMP_HOME}/bootstrap-signal-${cancel_signal}-home"
  signal_ready="${TMP_HOME}/bootstrap-signal-${cancel_signal}.ready"
  signal_marker="${TMP_HOME}/bootstrap-signal-${cancel_signal}.marker"
  signal_out="${TMP_HOME}/bootstrap-signal-${cancel_signal}.out"
  mkdir -p "${signal_home}"
  env "${bootstrap_base_env[@]}" HOME="${signal_home}" \
    VIBEGUARD_TEST_RELEASE_DIR="${signal_release}" \
    VIBEGUARD_TEST_SETUP_READY="${signal_ready}" \
    VIBEGUARD_TEST_SIGNAL_MARKER="${signal_marker}" \
    python3 -c 'import os, signal, sys
for name in ("SIGINT", "SIGTERM", "SIGHUP"):
    signal.signal(getattr(signal, name), signal.SIG_DFL)
os.execvpe("bash", ["bash", *sys.argv[1:]], os.environ)' \
      "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
    >"${signal_out}" 2>&1 &
  signal_parent_pid=$!
  for _signal_ready_attempt in {1..200}; do
    [[ -s "${signal_ready}" ]] && break
    sleep 0.05
  done
  read -r signal_leader_pid signal_child_pid < "${signal_ready}"
  signal_leader_pgid="$(ps -p "${signal_leader_pid}" -o pgid= | tr -d '[:space:]')"
  signal_child_pgid="$(ps -p "${signal_child_pid}" -o pgid= | tr -d '[:space:]')"
  assert_cmd "${cancel_signal} fixture places setup leader and child in one isolated group" \
    test "${signal_leader_pid}" = "${signal_leader_pgid}" -a \
      "${signal_leader_pgid}" = "${signal_child_pgid}"
  kill -s "${cancel_signal}" "${signal_parent_pid}"
  for _signal_exit_attempt in {1..200}; do
    kill -0 "${signal_parent_pid}" 2>/dev/null || break
    sleep 0.05
  done
  signal_parent_rc=0
  if kill -0 "${signal_parent_pid}" 2>/dev/null; then
    kill -KILL -- "-${signal_leader_pgid}" 2>/dev/null || true
    kill -KILL "${signal_parent_pid}" 2>/dev/null || true
    wait "${signal_parent_pid}" 2>/dev/null || true
    signal_parent_rc=124
  else
    wait "${signal_parent_pid}" || signal_parent_rc=$?
  fi
  assert_cmd "bootstrap exits with conventional ${cancel_signal} status after forwarding" \
    test "${signal_parent_rc}" -eq "${cancel_status}"
  assert_cmd "bootstrap forwards ${cancel_signal} to setup leader and child" bash -c \
    'grep -qFx "leader:$1" "$2" && grep -qFx "child:$1" "$2"' _ \
    "${cancel_signal}" "${signal_marker}"
  assert_cmd "bootstrap reaps ${cancel_signal} setup group and releases lease ownership" bash -c \
    '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null && test ! -e "$3" && test -z "$(find "$4" -maxdepth 1 -name ".bootstrap.lock.lease.*" -print -quit)"' _ \
    "${signal_leader_pid}" "${signal_child_pid}" \
    "${signal_home}/.vibeguard/dist/.bootstrap.lock" \
    "${signal_home}/.vibeguard/dist"
done

ignored_signal_release="${TMP_HOME}/bootstrap-release-signal-ignore"
make_hostile_bootstrap_release "${ignored_signal_release}" signal-ignore
ignored_signal_home="${TMP_HOME}/bootstrap-signal-ignore-home"
ignored_signal_ready="${TMP_HOME}/bootstrap-signal-ignore.ready"
ignored_signal_out="${TMP_HOME}/bootstrap-signal-ignore.out"
mkdir -p "${ignored_signal_home}"
env "${bootstrap_base_env[@]}" HOME="${ignored_signal_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${ignored_signal_release}" \
  VIBEGUARD_TEST_SETUP_READY="${ignored_signal_ready}" \
  python3 -c 'import os, signal, sys
for name in ("SIGINT", "SIGTERM", "SIGHUP"):
    signal.signal(getattr(signal, name), signal.SIG_DFL)
os.execvpe("bash", ["bash", *sys.argv[1:]], os.environ)' \
    "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${ignored_signal_out}" 2>&1 &
ignored_signal_parent_pid=$!
for _ignored_signal_ready_attempt in {1..200}; do
  [[ -s "${ignored_signal_ready}" ]] && break
  sleep 0.05
done
read -r ignored_signal_leader_pid ignored_signal_child_pid < "${ignored_signal_ready}"
ignored_signal_pgid="$(ps -p "${ignored_signal_leader_pid}" -o pgid= | tr -d '[:space:]')"
assert_cmd "ignored-signal fixture uses one isolated setup process group" bash -c \
  'test "$1" = "$2" && test "$2" = "$(ps -p "$3" -o pgid= | tr -d "[:space:]")"' _ \
  "${ignored_signal_leader_pid}" "${ignored_signal_pgid}" "${ignored_signal_child_pid}"
ignored_signal_started="${SECONDS}"
kill -TERM "${ignored_signal_parent_pid}"
for _ignored_signal_exit_attempt in {1..240}; do
  kill -0 "${ignored_signal_parent_pid}" 2>/dev/null || break
  sleep 0.05
done
ignored_signal_parent_rc=0
if kill -0 "${ignored_signal_parent_pid}" 2>/dev/null; then
  kill -KILL -- "-${ignored_signal_pgid}" 2>/dev/null || true
  kill -KILL "${ignored_signal_parent_pid}" 2>/dev/null || true
  wait "${ignored_signal_parent_pid}" 2>/dev/null || true
  ignored_signal_parent_rc=124
else
  wait "${ignored_signal_parent_pid}" || ignored_signal_parent_rc=$?
fi
ignored_signal_elapsed=$((SECONDS - ignored_signal_started))
assert_cmd "bootstrap preserves conventional TERM status after bounded KILL escalation" \
  test "${ignored_signal_parent_rc}" -eq 143
assert_contains "$(cat "${ignored_signal_out}")" "escalating to KILL" \
  "ignored TERM is visibly escalated to group-wide KILL"
assert_cmd "ignored-signal cancellation completes within the bounded termination budget" \
  test "${ignored_signal_elapsed}" -lt 10
assert_cmd "KILL escalation removes ignored-signal group and releases ownership" bash -c \
  '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null && test ! -e "$3" && test -z "$(find "$4" -maxdepth 1 -name ".bootstrap.lock.lease.*" -print -quit)"' _ \
  "${ignored_signal_leader_pid}" "${ignored_signal_child_pid}" \
  "${ignored_signal_home}/.vibeguard/dist/.bootstrap.lock" \
  "${ignored_signal_home}/.vibeguard/dist"

orphan_setup_home="${TMP_HOME}/bootstrap-orphan-setup-home"
orphan_setup_ready="${TMP_HOME}/bootstrap-orphan-setup.ready"
orphan_setup_fifo="${TMP_HOME}/bootstrap-orphan-setup.fifo"
orphan_setup_first_out="${TMP_HOME}/bootstrap-orphan-setup-first.out"
orphan_setup_retry_out="${TMP_HOME}/bootstrap-orphan-setup-retry.out"
mkdir -p "${orphan_setup_home}"
mkfifo "${orphan_setup_fifo}"
env "${bootstrap_base_env[@]}" \
  HOME="${orphan_setup_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  VIBEGUARD_TEST_SETUP_READY="${orphan_setup_ready}" \
  VIBEGUARD_TEST_SETUP_CONTINUE_FIFO="${orphan_setup_fifo}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${orphan_setup_first_out}" 2>&1 &
orphan_setup_parent_pid=$!
for _orphan_setup_attempt in {1..100}; do
  [[ -s "${orphan_setup_ready}" ]] && break
  sleep 0.05
done
orphan_setup_pid="$(cat "${orphan_setup_ready}" 2>/dev/null || true)"
assert_cmd "bootstrap publishes the setup child handshake before parent crash" bash -c \
  'test "$1" -gt 1 && kill -0 "$1"' _ "${orphan_setup_pid:-0}"
kill -KILL "${orphan_setup_parent_pid}"
wait "${orphan_setup_parent_pid}" 2>/dev/null || true
assert_cmd "setup child remains active after bootstrap parent SIGKILL" \
  kill -0 "${orphan_setup_pid}"

orphan_setup_retry_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${orphan_setup_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  VIBEGUARD_TEST_SETUP_READY="${orphan_setup_ready}" \
  VIBEGUARD_TEST_SETUP_CONTINUE_FIFO="${orphan_setup_fifo}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${orphan_setup_retry_out}" 2>&1 &
orphan_setup_retry_pid=$!
for _orphan_retry_attempt in {1..100}; do
  kill -0 "${orphan_setup_retry_pid}" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "${orphan_setup_retry_pid}" 2>/dev/null; then
  orphan_setup_retry_child="$(cat "${orphan_setup_ready}" 2>/dev/null || true)"
  kill -KILL "${orphan_setup_retry_pid}" 2>/dev/null || true
  wait "${orphan_setup_retry_pid}" 2>/dev/null || true
  kill -TERM "${orphan_setup_retry_child}" 2>/dev/null || true
  orphan_setup_retry_rc=124
else
  wait "${orphan_setup_retry_pid}" || orphan_setup_retry_rc=$?
fi
assert_cmd "retry fails closed while orphaned setup child is active" \
  test "${orphan_setup_retry_rc}" -eq 73
assert_contains "$(cat "${orphan_setup_retry_out}")" "setup process group" \
  "retry identifies the active setup lease"
assert_cmd "active setup retry preserves lock, payload, and transaction" bash -c \
  'test -f "$1" && test -d "$2" && grep -qFx "phase=setup" "$3"' _ \
  "${orphan_setup_home}/.vibeguard/dist/.bootstrap.lock" \
  "${orphan_setup_home}/.vibeguard/dist/${BOOTSTRAP_VERSION}" \
  "${orphan_setup_home}/.vibeguard/dist/.bootstrap-transaction-${BOOTSTRAP_VERSION}"
printf 'continue\n' > "${orphan_setup_fifo}"
for _orphan_child_attempt in {1..100}; do
  kill -0 "${orphan_setup_pid}" 2>/dev/null || break
  sleep 0.05
done
assert_cmd "orphaned setup child finishes without its killed parent" \
  bash -c '! kill -0 "$1" 2>/dev/null' _ "${orphan_setup_pid}"

dual_recovery_home="${TMP_HOME}/bootstrap-dual-recovery-home"
dual_recovery_ready="${TMP_HOME}/bootstrap-dual-recovery.ready"
dual_recovery_setup_fifo="${TMP_HOME}/bootstrap-dual-recovery-setup.fifo"
dual_recovery_ps_fifo="${TMP_HOME}/bootstrap-dual-recovery-ps.fifo"
dual_recovery_ps_ready="${TMP_HOME}/bootstrap-dual-recovery-ps.ready"
dual_recovery_bin="${TMP_HOME}/bootstrap-dual-recovery-bin"
dual_recovery_first_out="${TMP_HOME}/bootstrap-dual-recovery-first.out"
dual_recovery_second_out="${TMP_HOME}/bootstrap-dual-recovery-second.out"
dual_recovery_real_ps="$(command -v ps)"
mkdir -p "${dual_recovery_home}" "${dual_recovery_bin}"
mkfifo "${dual_recovery_setup_fifo}" "${dual_recovery_ps_fifo}"
env "${bootstrap_base_env[@]}" \
  HOME="${dual_recovery_home}" \
  VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  VIBEGUARD_TEST_SETUP_READY="${dual_recovery_ready}" \
  VIBEGUARD_TEST_SETUP_CONTINUE_FIFO="${dual_recovery_setup_fifo}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >/dev/null 2>&1 &
dual_recovery_parent_pid=$!
for _dual_recovery_setup_attempt in {1..100}; do
  [[ -s "${dual_recovery_ready}" ]] && break
  sleep 0.05
done
dual_recovery_setup_pid="$(cat "${dual_recovery_ready}" 2>/dev/null || true)"
assert_cmd "dual-recovery fixture starts an isolated setup child" bash -c \
  'test "$1" -gt 1 && kill -0 "$1"' _ "${dual_recovery_setup_pid:-0}"
kill -KILL "${dual_recovery_parent_pid}"
wait "${dual_recovery_parent_pid}" 2>/dev/null || true
dual_recovery_nonce="$(awk -F= '$1 == "nonce" { print $2 }' \
  "${dual_recovery_home}/.vibeguard/dist/.bootstrap.lock")"
dual_recovery_lease="${dual_recovery_home}/.vibeguard/dist/.bootstrap.lock.lease.${dual_recovery_nonce}"
cat > "${dual_recovery_bin}/ps" <<SH
#!/usr/bin/env bash
if [[ "\$*" == *"pgid="* && ! -e "${dual_recovery_ps_ready}" ]]; then
  : > "${dual_recovery_ps_ready}"
  IFS= read -r _signal < "${dual_recovery_ps_fifo}"
fi
exec "${dual_recovery_real_ps}" "\$@"
SH
chmod +x "${dual_recovery_bin}/ps"
dual_recovery_first_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${dual_recovery_home}" PATH="${dual_recovery_bin}:${PATH}" \
  VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${dual_recovery_first_out}" 2>&1 &
dual_recovery_first_pid=$!
for _dual_recovery_pause_attempt in {1..100}; do
  [[ -e "${dual_recovery_ps_ready}" ]] && break
  sleep 0.05
done
assert_cmd "first stale recoverer pauses during setup-group liveness proof" \
  test -e "${dual_recovery_ps_ready}"
dual_recovery_second_rc=0
env "${bootstrap_base_env[@]}" \
  HOME="${dual_recovery_home}" VIBEGUARD_TEST_RELEASE_DIR="${lock_wait_release}" \
  bash "${BOOTSTRAP}" --version "${BOOTSTRAP_VERSION}" -- --yes \
  >"${dual_recovery_second_out}" 2>&1 || dual_recovery_second_rc=$?
assert_cmd "second stale recoverer fails closed while the setup group is active" \
  test "${dual_recovery_second_rc}" -eq 73
assert_contains "$(cat "${dual_recovery_second_out}")" "setup process group" \
  "second stale recoverer observes the canonical active lease"
assert_cmd "dual stale recovery preserves lock, lease, and active setup child" bash -c \
  'test -f "$1" && test -f "$2" && kill -0 "$3" && test -z "$(find "$4" -maxdepth 1 -name ".bootstrap.lock.lease.*.reap.*" -print -quit)"' _ \
  "${dual_recovery_home}/.vibeguard/dist/.bootstrap.lock" \
  "${dual_recovery_lease}" "${dual_recovery_setup_pid}" \
  "${dual_recovery_home}/.vibeguard/dist"
printf 'continue\n' > "${dual_recovery_ps_fifo}"
wait "${dual_recovery_first_pid}" || dual_recovery_first_rc=$?
assert_cmd "first stale recoverer also fails closed after liveness proof" \
  test "${dual_recovery_first_rc}" -eq 73
printf 'continue\n' > "${dual_recovery_setup_fifo}"
for _dual_recovery_child_attempt in {1..100}; do
  kill -0 "${dual_recovery_setup_pid}" 2>/dev/null || break
  sleep 0.05
done
assert_cmd "dual-recovery orphaned setup child exits after test release" \
  bash -c '! kill -0 "$1" 2>/dev/null' _ "${dual_recovery_setup_pid}"
