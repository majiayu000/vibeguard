#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/hook_test_lib.sh"
hook_test_init

header "wrappers precompute hook runtime env"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR" "$VIBEGUARD_LOG_DIR"' EXIT

TMP_HOME="${WORK_DIR}/home"
INSTALLED_HOOKS="${TMP_HOME}/.vibeguard/installed/hooks"
mkdir -p "$INSTALLED_HOOKS"

cat > "${INSTALLED_HOOKS}/probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'HASH=%s\n' "${VIBEGUARD_PROJECT_HASH:-}"
printf 'DIR=%s\n' "${VIBEGUARD_PROJECT_LOG_DIR:-}"
printf 'FILE=%s\n' "${VIBEGUARD_LOG_FILE:-}"
printf 'SESSION=%s\n' "${VIBEGUARD_SESSION_ID:-}"
printf 'CLI=%s\n' "${VIBEGUARD_CLI:-}"
printf 'PYTHONUTF8=%s\n' "${PYTHONUTF8:-}"
EOF
chmod +x "${INSTALLED_HOOKS}/probe.sh"

repo_root="$(git rev-parse --show-toplevel)"
expected_hash="$(printf '%s' "$repo_root" | shasum -a 256 2>/dev/null | cut -c1-8)"
log_root="${WORK_DIR}/logs"
out_file="${WORK_DIR}/run-hook.out"

HOME="$TMP_HOME" VIBEGUARD_LOG_DIR="$log_root" bash hooks/run-hook.sh probe.sh >> "$out_file"
HOME="$TMP_HOME" VIBEGUARD_LOG_DIR="$log_root" bash hooks/run-hook.sh probe.sh >> "$out_file"

out="$(cat "$out_file")"
assert_contains "$out" "HASH=${expected_hash}" "run-hook exports stable project hash"
assert_contains "$out" "DIR=${log_root}/projects/${expected_hash}" "run-hook exports project log dir"
assert_contains "$out" "FILE=${log_root}/projects/${expected_hash}/events.jsonl" "run-hook exports project log file"
assert_contains "$out" "CLI=claude" "run-hook defaults CLI to claude"
assert_contains "$out" "PYTHONUTF8=1" "run-hook exports UTF-8 Python env"

session_count="$(awk -F= '/^SESSION=/{print $2}' "$out_file" | sort -u | wc -l | tr -d ' ')"
TOTAL=$((TOTAL + 1))
if [[ "$session_count" == "1" ]]; then
  green "run-hook reuses one wrapper-computed session id across invocations"
  PASS=$((PASS + 1))
else
  red "run-hook session id should be reused, got ${session_count} unique ids"
  FAIL=$((FAIL + 1))
fi

cat > "${INSTALLED_HOOKS}/vibeguard-env-probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'HASH=%s\n' "${VIBEGUARD_PROJECT_HASH:-}"
  printf 'DIR=%s\n' "${VIBEGUARD_PROJECT_LOG_DIR:-}"
  printf 'FILE=%s\n' "${VIBEGUARD_LOG_FILE:-}"
  printf 'SESSION=%s\n' "${VIBEGUARD_SESSION_ID:-}"
  printf 'CLI=%s\n' "${VIBEGUARD_CLI:-}"
} >> "${VG_PROBE_OUT:?}"
EOF
chmod +x "${INSTALLED_HOOKS}/vibeguard-env-probe.sh"

codex_log_root="${WORK_DIR}/codex-logs"
codex_out="${WORK_DIR}/codex.out"
printf '{"hook_event_name":"Stop"}' \
  | HOME="$TMP_HOME" VIBEGUARD_LOG_DIR="$codex_log_root" VG_PROBE_OUT="$codex_out" \
    bash hooks/run-hook-codex.sh vibeguard-env-probe.sh

codex_probe="$(cat "$codex_out")"
assert_contains "$codex_probe" "HASH=${expected_hash}" "run-hook-codex exports stable project hash"
assert_contains "$codex_probe" "DIR=${codex_log_root}/projects/${expected_hash}" "run-hook-codex exports project log dir"
assert_contains "$codex_probe" "FILE=${codex_log_root}/projects/${expected_hash}/events.jsonl" "run-hook-codex exports project log file"
assert_contains "$codex_probe" "CLI=codex" "run-hook-codex preserves codex CLI marker"

hook_test_finish
