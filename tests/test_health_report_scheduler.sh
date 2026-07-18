#!/usr/bin/env bash
# VibeGuard health report scheduler regression testing.
#
# Usage: bash tests/test_health_report_scheduler.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEDULED_SCRIPT="${REPO_DIR}/scripts/health-report-scheduled.sh"
INSTALLER="${REPO_DIR}/scripts/install-health-report-scheduler.sh"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$expected" <<< "$output"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (exit code: $?)"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
ORIG_HOME="${HOME}"
cleanup() {
  export HOME="${ORIG_HOME}"
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

header "fixtures"
export HOME="${TMP_DIR}/home"
mkdir -p "${HOME}"
EVENTS="${TMP_DIR}/events.jsonl"
TRIAGE="${TMP_DIR}/triage.jsonl"
SCORECARD="${TMP_DIR}/scorecard.json"
ADOPTIONS="${TMP_DIR}/adoptions.jsonl"
REPORT_DIR="${TMP_DIR}/reports"
cat > "${EVENTS}" <<'JSONL'
{"ts":"2026-07-05T00:00:00Z","session":"s1","hook":"analysis-paralysis-guard","tool":"Read","decision":"warn","reason":"W-13 paralysis 7x","client":"claude"}
JSONL
cat > "${TRIAGE}" <<'JSONL'
{"schema_version":1,"ts":"2026-07-05T00:00:00Z","rule":"W-13","verdict":"unclassified","decision":"warn","hook":"analysis-paralysis-guard","tool":"Read","context":"W-13 paralysis 7x","session":"s1"}
JSONL
cat > "${SCORECARD}" <<'JSON'
{"rules":{"W-13":{"stage":"warn","precision":null,"samples":0,"tp":0,"fp":0,"acceptable":0,"last_fp_ts":null}}}
JSON
: > "${ADOPTIONS}"

header "scheduled wrapper dry-run"
dry_run_out="$(bash "${SCHEDULED_SCRIPT}" \
  --dry-run \
  --days 30 \
  --scope global \
  --log-file "${EVENTS}" \
  --triage-file "${TRIAGE}" \
  --scorecard-file "${SCORECARD}" \
  --adoptions-file "${ADOPTIONS}" \
  --output-dir "${REPORT_DIR}" \
  --report-date 2026-07-06)"
assert_contains "${dry_run_out}" "Health report scheduler dry run" "scheduled wrapper reports dry-run mode"
assert_contains "${dry_run_out}" "${REPORT_DIR}/2026-07-06.md" "scheduled wrapper previews deterministic output path"
assert_cmd "scheduled wrapper dry-run does not write report" test ! -e "${REPORT_DIR}/2026-07-06.md"

header "scheduled wrapper writes report"
write_out="$(bash "${SCHEDULED_SCRIPT}" \
  --days 30 \
  --scope global \
  --log-file "${EVENTS}" \
  --triage-file "${TRIAGE}" \
  --scorecard-file "${SCORECARD}" \
  --adoptions-file "${ADOPTIONS}" \
  --output-dir "${REPORT_DIR}" \
  --report-date 2026-07-06)"
assert_contains "${write_out}" "Wrote markdown report to" "scheduled wrapper writes report through health-report.py"
assert_cmd "scheduled wrapper created report file" test -f "${REPORT_DIR}/2026-07-06.md"
report_text="$(cat "${REPORT_DIR}/2026-07-06.md")"
assert_contains "${report_text}" "# VibeGuard Health Report" "scheduled report contains markdown header"
assert_contains "${report_text}" "W-13" "scheduled report carries W-13 evidence"

header "installer default is non-mutating"
install_plan_out="$(VIBEGUARD_HEALTH_REPORT_TEST_UNAME=Darwin \
  VIBEGUARD_HEALTH_REPORT_TEST_SKIP_LAUNCHCTL=1 \
  bash "${INSTALLER}" --repo-dir "${REPO_DIR}" --output-dir "${REPORT_DIR}")"
assert_contains "${install_plan_out}" "No scheduler installed" "installer default does not install"
assert_cmd "installer default does not write launchd plist" test ! -e "${HOME}/Library/LaunchAgents/com.vibeguard.health-report.plist"

header "manual opt-in launchd install"
LAUNCHD_REPORT_DIR="${TMP_DIR}/reports & launchd"
launchd_out="$(VIBEGUARD_HEALTH_REPORT_TEST_UNAME=Darwin \
  VIBEGUARD_HEALTH_REPORT_TEST_SKIP_LAUNCHCTL=1 \
  bash "${INSTALLER}" --install --repo-dir "${REPO_DIR}" --output-dir "${LAUNCHD_REPORT_DIR}")"
assert_contains "${launchd_out}" "Installed launchd scheduler" "manual opt-in installs launchd plist"
PLIST="${HOME}/Library/LaunchAgents/com.vibeguard.health-report.plist"
assert_cmd "launchd plist was written" test -f "${PLIST}"
plist_text="$(cat "${PLIST}")"
assert_contains "${plist_text}" "scripts/health-report-scheduled.sh" "launchd plist points to scheduled health wrapper"
assert_contains "${plist_text}" "reports &amp; launchd" "launchd plist XML-escapes output directory"

header "manual opt-in cron install"
CRONTAB_FILE="${TMP_DIR}/crontab"
CRON_REPORT_DIR="${TMP_DIR}/reports quote ' cron"
cron_out="$(VIBEGUARD_HEALTH_REPORT_TEST_UNAME=Linux \
  VIBEGUARD_HEALTH_REPORT_TEST_CRONTAB="${CRONTAB_FILE}" \
  bash "${INSTALLER}" --install --repo-dir "${REPO_DIR}" --output-dir "${CRON_REPORT_DIR}")"
assert_contains "${cron_out}" "Installed cron scheduler" "manual opt-in installs cron entry"
cron_text="$(cat "${CRONTAB_FILE}")"
assert_contains "${cron_text}" "VibeGuard health report scheduler start" "cron install uses managed marker"
assert_contains "${cron_text}" "scripts/health-report-scheduled.sh" "cron install points to scheduled health wrapper"
assert_contains "${cron_text}" "'\\''" "cron install shell-quotes output directory"

printf '\n\033[1m=== Summary ===\033[0m\n'
printf 'Total: %d  Passed: %d  Failed: %d\n' "$TOTAL" "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
