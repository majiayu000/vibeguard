#!/usr/bin/env bash
# Unit tests for hooks/_lib/session_metrics.py — missing env var fallback paths
#
# Covers two guard paths added in PR #93:
#   line  39: VIBEGUARD_SESSION_ID missing  → os.environ.get("...", "") + early sys.exit(0)
#   line 161: VIBEGUARD_PROJECT_LOG_DIR missing → os.environ.get("...", "") + early sys.exit(0)
#
# bench_hook_latency.sh always supplies both vars, so these paths were untested.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_DIR}/hooks/_lib/session_metrics.py"

PASS=0; FAIL=0; TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

# ── Fixture helpers ────────────────────────────────────────────────────────────
TMPDIR_TEST=""

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  # Write events with timestamps in the last 30 minutes (5 events, same session)
  python3 - <<'PYEOF' > "${TMPDIR_TEST}/events.jsonl"
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
for i in range(5):
    ts = (now - datetime.timedelta(seconds=i * 10)).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(json.dumps({"ts": ts, "session": "testsession01", "hook": "post-edit-guard",
                      "tool": "Edit", "decision": "pass", "reason": "", "detail": f"src/file{i}.rs"}))
PYEOF
}

teardown() {
  [[ -n "${TMPDIR_TEST:-}" ]] && rm -rf "$TMPDIR_TEST"
}

# ── Tests ──────────────────────────────────────────────────────────────────────

printf '\n=== session_metrics.py env var guard paths ===\n'

# ── 1. Missing VIBEGUARD_PROJECT_LOG_DIR: exits 0 (no crash) ─────────────────
printf '\n--- Missing VIBEGUARD_PROJECT_LOG_DIR (line 161 guard) ---\n'

setup
TOTAL=$((TOTAL + 1))
exit_code=0
env -u VIBEGUARD_PROJECT_LOG_DIR \
  VIBEGUARD_LOG_FILE="${TMPDIR_TEST}/events.jsonl" \
  VIBEGUARD_SESSION_ID="testsession01" \
  python3 "${SCRIPT}" >/dev/null 2>&1 || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
  green "Missing VIBEGUARD_PROJECT_LOG_DIR: exits 0 (early-exit guard works)"; PASS=$((PASS + 1))
else
  red "Missing VIBEGUARD_PROJECT_LOG_DIR: expected exit 0, got $exit_code"; FAIL=$((FAIL + 1))
fi
teardown

# ── 2. Missing VIBEGUARD_PROJECT_LOG_DIR: no metrics file written ─────────────
# The early sys.exit(0) at line 163 fires before the write at line 201.
setup
TOTAL=$((TOTAL + 1))
env -u VIBEGUARD_PROJECT_LOG_DIR \
  VIBEGUARD_LOG_FILE="${TMPDIR_TEST}/events.jsonl" \
  VIBEGUARD_SESSION_ID="testsession01" \
  python3 "${SCRIPT}" >/dev/null 2>&1 || true
if [[ ! -f "${TMPDIR_TEST}/session-metrics.jsonl" ]]; then
  green "Missing VIBEGUARD_PROJECT_LOG_DIR: no metrics file written (exited before write)"; PASS=$((PASS + 1))
else
  red "Missing VIBEGUARD_PROJECT_LOG_DIR: metrics file should not exist after early exit"; FAIL=$((FAIL + 1))
fi
teardown

# ── 3. Missing VIBEGUARD_SESSION_ID: exits 0, no crash ───────────────────────
printf '\n--- Missing VIBEGUARD_SESSION_ID (line 39 guard) ---\n'

setup
TOTAL=$((TOTAL + 1))
exit_code=0
env -u VIBEGUARD_SESSION_ID \
  VIBEGUARD_LOG_FILE="${TMPDIR_TEST}/events.jsonl" \
  VIBEGUARD_PROJECT_LOG_DIR="${TMPDIR_TEST}" \
  python3 "${SCRIPT}" >/dev/null 2>&1 || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
  green "Missing VIBEGUARD_SESSION_ID: exits 0 (early-exit guard works)"; PASS=$((PASS + 1))
else
  red "Missing VIBEGUARD_SESSION_ID: expected exit 0, got $exit_code"; FAIL=$((FAIL + 1))
fi
teardown

# ── 4. Missing VIBEGUARD_SESSION_ID: no metrics file written ─────────────────
# The early sys.exit(0) at line 41 fires before any event aggregation or write.
# Cross-session data must not be included under an empty session value.
setup
python3 - <<'PYEOF' > "${TMPDIR_TEST}/events_multi.jsonl"
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
for sess in ("sessionA", "sessionB"):
    for i in range(3):
        ts = (now - datetime.timedelta(seconds=i * 10)).strftime("%Y-%m-%dT%H:%M:%SZ")
        print(json.dumps({"ts": ts, "session": sess, "hook": "post-edit-guard",
                          "tool": "Edit", "decision": "pass", "reason": "", "detail": f"src/file{i}.rs"}))
PYEOF
TOTAL=$((TOTAL + 1))
env -u VIBEGUARD_SESSION_ID \
  VIBEGUARD_LOG_FILE="${TMPDIR_TEST}/events_multi.jsonl" \
  VIBEGUARD_PROJECT_LOG_DIR="${TMPDIR_TEST}" \
  python3 "${SCRIPT}" >/dev/null 2>&1 || true
if [[ ! -f "${TMPDIR_TEST}/session-metrics.jsonl" ]]; then
  green "Missing VIBEGUARD_SESSION_ID: no metrics file written (early-exit before aggregation)"; PASS=$((PASS + 1))
else
  red "Missing VIBEGUARD_SESSION_ID: metrics file must not exist when session ID is missing"; FAIL=$((FAIL + 1))
fi
teardown

# ── 5. Missing VIBEGUARD_LOG_FILE: exits 0 with empty stdout ─────────────────
printf '\n--- Missing VIBEGUARD_LOG_FILE (line 35 guard) ---\n'

setup
TOTAL=$((TOTAL + 1))
exit_code=0
output="$(env -u VIBEGUARD_LOG_FILE \
  VIBEGUARD_SESSION_ID="testsession01" \
  VIBEGUARD_PROJECT_LOG_DIR="${TMPDIR_TEST}" \
  python3 "${SCRIPT}" 2>/dev/null)" || exit_code=$?
if [[ $exit_code -eq 0 && -z "$output" ]]; then
  green "Missing VIBEGUARD_LOG_FILE: exits 0 with empty stdout (early-exit guard works)"; PASS=$((PASS + 1))
else
  red "Missing VIBEGUARD_LOG_FILE: expected exit 0 with empty stdout, got exit=$exit_code output='$output'"; FAIL=$((FAIL + 1))
fi
teardown

# ── 6. Missing VIBEGUARD_LOG_FILE: no metrics file written ───────────────────
# The early sys.exit(0) at line 36 fires before any event aggregation or write.
setup
TOTAL=$((TOTAL + 1))
env -u VIBEGUARD_LOG_FILE \
  VIBEGUARD_SESSION_ID="testsession01" \
  VIBEGUARD_PROJECT_LOG_DIR="${TMPDIR_TEST}" \
  python3 "${SCRIPT}" >/dev/null 2>&1 || true
if [[ ! -f "${TMPDIR_TEST}/session-metrics.jsonl" ]]; then
  green "Missing VIBEGUARD_LOG_FILE: no metrics file written (exited before write)"; PASS=$((PASS + 1))
else
  red "Missing VIBEGUARD_LOG_FILE: metrics file should not exist after early exit"; FAIL=$((FAIL + 1))
fi
teardown

# ── Summary ───────────────────────────────────────────────────────────────────
echo
printf 'Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
