#!/usr/bin/env bash
# Tests for the structured `setup.sh --check` health report.
#
# Strategy
#   These tests do not depend on the real ~/.claude or ~/.codex install
#   state. We feed synthetic legacy-style output through the
#   status_report.sh library directly so we can assert tally, verdict,
#   exit code, JSON shape, and quiet-mode filtering behavior without
#   touching the user's home directory.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATUS_LIB="${REPO_DIR}/scripts/lib/status_report.sh"
CHECK_SCRIPT="${REPO_DIR}/scripts/setup/check.sh"
SETUP_SCRIPT="${REPO_DIR}/setup.sh"
AWK_PORTABILITY_FIXTURE=""
STALE_HOOK_HOME=""

cleanup() {
  if [[ -n "${AWK_PORTABILITY_FIXTURE}" ]]; then
    rm -f "${AWK_PORTABILITY_FIXTURE}"
  fi
  if [[ -n "${STALE_HOOK_HOME}" ]]; then
    rm -rf "${STALE_HOOK_HOME}"
  fi
}
trap cleanup EXIT

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$output" | grep -qF -- "$expected"; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" forbidden="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$output" | grep -qF -- "$forbidden"; then
    red "$desc (must not contain: $forbidden)"; FAIL=$((FAIL + 1))
  else
    green "$desc"; PASS=$((PASS + 1))
  fi
}

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" == "$expected" ]]; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected '${expected}', got '${actual}')"; FAIL=$((FAIL + 1))
  fi
}

# assert_json_path <json_text> <python_expr_returning_value> <expected> <desc>
# Parses <json_text> with python3 and evaluates <python_expr> against the
# loaded document (variable name `d`). Prints PASS/FAIL.
assert_json_path() {
  local doc="$1" expr="$2" expected="$3" desc="$4"
  TOTAL=$((TOTAL + 1))
  local actual
  actual="$(VG_DOC="$doc" VG_EXPR="$expr" python3 -c '
import json, os, sys
d = json.loads(os.environ["VG_DOC"])
print(eval(os.environ["VG_EXPR"]))
' 2>/dev/null)"
  if [[ "$actual" == "$expected" ]]; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected '${expected}', got '${actual}')"; FAIL=$((FAIL + 1))
  fi
}

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (cmd: $*)"; FAIL=$((FAIL + 1))
  fi
}

# --- Syntax checks ---
header "syntax"
assert_cmd "scripts/lib/status_report.sh syntax" bash -n "${STATUS_LIB}"
assert_cmd "scripts/setup/check.sh syntax" bash -n "${CHECK_SCRIPT}"

# --- Library unit tests via a synthetic buffer ---
header "status_report library tally"

run_with_buffer() {
  # $1 = buffer file content (multiline)
  # $2 = command to invoke after sourcing the library, in this shell.
  local content="$1"
  local cmd="$2"
  local buf
  buf="$(mktemp -t vg-test-buf.XXXXXX)"
  printf '%s' "$content" > "$buf"
  (
    set +e
    # shellcheck source=/dev/null
    source "${STATUS_LIB}"
    status_init "$buf"
    status_record_buffer
    eval "$cmd"
  )
  local rc=$?
  rm -f "$buf"
  return $rc
}

# Healthy buffer — only [OK] rows.
healthy_buf=$'[OK] thing one\n[OK] thing two\n[OK] thing three\n'
healthy_summary="$(run_with_buffer "$healthy_buf" 'status_print_summary')"
assert_contains "$healthy_summary" "OK      : 3"        "healthy: ok count"
assert_contains "$healthy_summary" "Verdict :"          "healthy: verdict line present"
assert_contains "$healthy_summary" "HEALTHY"            "healthy: verdict is HEALTHY"
healthy_rc="$(run_with_buffer "$healthy_buf" 'status_exit_code')"
assert_eq "$healthy_rc" "0" "healthy: exit code 0"

# Degraded — only [WARN].
degraded_buf=$'[OK] base\n[WARN] something optional\n'
deg_summary="$(run_with_buffer "$degraded_buf" 'status_print_summary')"
assert_contains "$deg_summary" "WARN    : 1"  "degraded: warn count"
assert_contains "$deg_summary" "DEGRADED"     "degraded: verdict is DEGRADED"
deg_rc="$(run_with_buffer "$degraded_buf" 'status_exit_code')"
assert_eq "$deg_rc" "1" "degraded: exit code 1"

# Broken — has [BROKEN] / [FAIL] / [MISSING].
broken_buf=$'[OK] foo\n[BROKEN] hook wrapper missing\n[MISSING] runtime binary\n[FAIL] schema invalid\n'
broken_summary="$(run_with_buffer "$broken_buf" 'status_print_summary')"
assert_contains "$broken_summary" "BROKEN  : 1"  "broken: broken count"
assert_contains "$broken_summary" "FAIL    : 1"  "broken: fail count"
assert_contains "$broken_summary" "MISSING : 1"  "broken: missing count"
assert_contains "$broken_summary" "BROKEN"       "broken: verdict is BROKEN"
broken_rc="$(run_with_buffer "$broken_buf" 'status_exit_code')"
assert_eq "$broken_rc" "2" "broken: exit code 2"

# [INFO] is neutral and never affects the verdict.
info_buf=$'[OK] up\n[INFO] optional module not configured\n'
info_summary="$(run_with_buffer "$info_buf" 'status_print_summary')"
assert_contains "$info_summary" "INFO    : 1"  "info: info count"
assert_contains "$info_summary" "HEALTHY"      "info: verdict still HEALTHY"
info_rc="$(run_with_buffer "$info_buf" 'status_exit_code')"
assert_eq "$info_rc" "0" "info: exit code 0"

# --- Quiet-mode problem filter ---
header "status_report quiet filter"
quiet_out="$(run_with_buffer "$broken_buf" 'status_print_summary --quiet')"
assert_contains "$quiet_out" "Problems"            "quiet: shows Problems header"
assert_contains "$quiet_out" "[BROKEN]"            "quiet: includes BROKEN row"
assert_contains "$quiet_out" "[MISSING]"           "quiet: includes MISSING row"
assert_contains "$quiet_out" "[FAIL]"              "quiet: includes FAIL row"
assert_not_contains "$quiet_out" "[OK] foo"        "quiet: drops OK rows"

# Healthy + quiet → no Problems block.
quiet_healthy="$(run_with_buffer "$healthy_buf" 'status_print_summary --quiet')"
assert_not_contains "$quiet_healthy" "Problems"    "quiet+healthy: no Problems block"

# --- JSON shape ---
header "status_report JSON output"
json_out="$(run_with_buffer "$broken_buf" 'status_emit_json')"
# Parse-driven assertions so we do not depend on key ordering or
# whitespace style of the chosen JSON encoder.
assert_json_path "$json_out" 'd["schema_version"]' "1"      "json: schema_version=1"
assert_json_path "$json_out" 'd["verdict"]'        "broken" "json: verdict=broken"
assert_json_path "$json_out" 'd["counts"]["broken"]'  "1"   "json: counts.broken=1"
assert_json_path "$json_out" 'd["counts"]["missing"]' "1"   "json: counts.missing=1"
assert_json_path "$json_out" 'd["counts"]["fail"]'    "1"   "json: counts.fail=1"
assert_json_path "$json_out" 'd["counts"]["ok"]'      "1"   "json: counts.ok=1"
assert_json_path "$json_out" 'len(d["events"])'       "4"   "json: 4 events captured"
assert_json_path "$json_out" 'sorted({e["level"] for e in d["events"]})' "['BROKEN', 'FAIL', 'MISSING', 'OK']" "json: event levels"

# JSON must be parseable.
TOTAL=$((TOTAL + 1))
if printf '%s' "$json_out" | python3 -c 'import json,sys;json.loads(sys.stdin.read())' 2>/dev/null; then
  green "json: output parses with python3 json.loads"; PASS=$((PASS + 1))
else
  red "json: output failed to parse"; FAIL=$((FAIL + 1))
fi

# Healthy JSON should report verdict=healthy.
healthy_json="$(run_with_buffer "$healthy_buf" 'status_emit_json')"
assert_json_path "$healthy_json" 'd["verdict"]' "healthy" "json: healthy verdict"

# Lines without a [LEVEL] prefix must not appear in events array.
mixed_buf=$'[OK] tag-line\nfree-form section header\n[INFO] tag-line\n'
mixed_json="$(run_with_buffer "$mixed_buf" 'status_emit_json')"
assert_not_contains "$mixed_json" "free-form section header" "json: untagged lines excluded from events"
assert_json_path "$mixed_json" 'd["counts"]["ok"]'   "1" "json: counts.ok unaffected by untagged lines"
assert_json_path "$mixed_json" 'd["counts"]["info"]' "1" "json: counts.info still counted"
assert_json_path "$mixed_json" 'len(d["events"])'    "2" "json: untagged line excluded from events"

# --- ANSI stripping ---
header "ANSI stripping"
# Real probes print colored output; the library must strip color before
# matching the [LEVEL] prefix. We feed a colorized buffer.
ansi_buf=$'\033[32m[OK] colorized ok\033[0m\n\033[31m[BROKEN] colorized broken\033[0m\n'
ansi_summary="$(run_with_buffer "$ansi_buf" 'status_print_summary')"
assert_contains "$ansi_summary" "OK      : 1"     "ansi: ok counted from colorized line"
assert_contains "$ansi_summary" "BROKEN  : 1"     "ansi: broken counted from colorized line"
ansi_json="$(run_with_buffer "$ansi_buf" 'status_emit_json')"
assert_not_contains "$ansi_json" $'\033['         "ansi: escape codes stripped from json"
assert_json_path "$ansi_json" 'd["events"][0]["message"]' "[OK] colorized ok" "ansi: ok message stored without color"
assert_json_path "$ansi_json" 'd["events"][1]["message"]' "[BROKEN] colorized broken" "ansi: broken message stored without color"

# --- Argument parsing on check.sh ---
header "check.sh argument parsing"

# Help should exit 0 and print usage.
help_out="$(bash "${SETUP_SCRIPT}" --check --help 2>&1)"
help_rc=$?
assert_eq "$help_rc" "0" "check --help: exit 0"
assert_contains "$help_out" "Usage: setup.sh --check" "check --help: prints usage"
assert_contains "$help_out" "Exit codes"             "check --help: documents exit codes"
assert_contains "$help_out" "--install"              "check --help: documents install verification mode"

# Unknown flag should exit 64 (sysexits.h EX_USAGE).
err_out="$(bash "${SETUP_SCRIPT}" --check --bogus 2>&1)"
err_rc=$?
assert_eq "$err_rc" "64" "check --bogus: exit 64"
assert_contains "$err_out" "unknown argument" "check --bogus: error message"

# Conflicting flags should be rejected.
conf_out="$(bash "${SETUP_SCRIPT}" --check --json --quiet 2>&1)"
conf_rc=$?
assert_eq "$conf_rc" "64" "check --json --quiet: rejected with exit 64"
assert_contains "$conf_out" "mutually exclusive" "check --json --quiet: error message"

conf_out2="$(bash "${SETUP_SCRIPT}" --check --json --no-summary 2>&1)"
conf_rc2=$?
assert_eq "$conf_rc2" "64" "check --json --no-summary: rejected with exit 64"

conf_out3="$(bash "${SETUP_SCRIPT}" --check --json --install 2>&1)"
conf_rc3=$?
assert_eq "$conf_rc3" "64" "check --json --install: rejected with exit 64"

# --- End-to-end check ---
header "check.sh end-to-end"
# We do not assert on exit code here (depends on the runner's home dir);
# we only assert the structural pieces we promised the user.
default_out="$(bash "${SETUP_SCRIPT}" --check 2>&1 || true)"
assert_contains "$default_out" "VibeGuard Installation Status" "default: legacy header preserved"
assert_contains "$default_out" "Summary"        "default: summary block present"
assert_contains "$default_out" "Verdict :"      "default: verdict line present"
assert_contains "$default_out" "[OK] All awk blocks use POSIX-compatible regex" "default: Python heredoc regexes do not trip awk portability"
assert_not_contains "$default_out" "check_dependency_changes.sh:147" "default: dependency Python regex not reported as awk"
assert_not_contains "$default_out" "check_test_weakening.sh:118" "default: test weakening Python regex not reported as awk"

AWK_PORTABILITY_FIXTURE="${REPO_DIR}/guards/universal/vg-test-non-posix-awk.sh"
cat > "${AWK_PORTABILITY_FIXTURE}" <<'SH'
#!/usr/bin/env bash
awk '/\sbad/ { print }' "$1"
SH
awk_fixture_out="$(bash "${SETUP_SCRIPT}" --check 2>&1 || true)"
assert_contains "$awk_fixture_out" "vg-test-non-posix-awk.sh" "check reports real non-POSIX awk regex"
rm -f "${AWK_PORTABILITY_FIXTURE}"
AWK_PORTABILITY_FIXTURE=""

no_summary_out="$(bash "${SETUP_SCRIPT}" --check --no-summary 2>&1 || true)"
assert_contains "$no_summary_out" "VibeGuard Installation Status" "no-summary: legacy header preserved"
assert_not_contains "$no_summary_out" "Verdict :" "no-summary: no verdict line"
# Use grep -Fxq for an anchored exact-line match — the literal "Summary"
# string appears as part of section labels, only the rollup uses it as a
# standalone line.
TOTAL=$((TOTAL + 1))
if printf '%s' "$no_summary_out" | grep -Fxq -- "Summary"; then
  red "no-summary: no Summary header line (found one)"; FAIL=$((FAIL + 1))
else
  green "no-summary: no Summary header line"; PASS=$((PASS + 1))
fi

json_full_out="$(bash "${SETUP_SCRIPT}" --check --json 2>&1 || true)"
TOTAL=$((TOTAL + 1))
if printf '%s' "$json_full_out" | python3 -c 'import json,sys;json.loads(sys.stdin.read())' 2>/dev/null; then
  green "json end-to-end: output parses"; PASS=$((PASS + 1))
else
  red "json end-to-end: output failed to parse"; FAIL=$((FAIL + 1))
fi
assert_json_path "$json_full_out" 'd["schema_version"]' "1" "json end-to-end: schema_version=1"
assert_json_path "$json_full_out" 'd["verdict"] in ("healthy","degraded","broken")' "True" "json end-to-end: verdict in expected set"

# --- Stale hook registry detection ---
header "stale hook registry detection"
STALE_HOOK_HOME="$(mktemp -d)"
mkdir -p "${STALE_HOOK_HOME}/.claude" "${STALE_HOOK_HOME}/.codex" "${STALE_HOOK_HOME}/.vibeguard/installed/hooks"
cp "${REPO_DIR}/hooks/run-hook.sh" "${STALE_HOOK_HOME}/.vibeguard/run-hook.sh"
cp "${REPO_DIR}/hooks/run-hook-codex.sh" "${STALE_HOOK_HOME}/.vibeguard/run-hook-codex.sh"
cp -R "${REPO_DIR}/hooks/." "${STALE_HOOK_HOME}/.vibeguard/installed/hooks/"
cat > "${STALE_HOOK_HOME}/.claude/settings.json" <<JSON
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${STALE_HOOK_HOME}/.vibeguard/installed/hooks/session-tagger.sh"
          }
        ]
      }
    ]
  }
}
JSON
cat > "${STALE_HOOK_HOME}/.codex/hooks.json" <<JSON
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${STALE_HOOK_HOME}/.vibeguard/installed/hooks/session-tagger.sh"
          }
        ]
      }
    ]
  }
}
JSON

stale_check_out="$(HOME="${STALE_HOOK_HOME}" bash "${SETUP_SCRIPT}" --check --strict 2>&1)"
stale_check_rc=$?
assert_eq "$stale_check_rc" "2" "stale hook check: strict mode exits broken"
assert_contains "$stale_check_out" "stale Claude hook command" "stale hook check: reports Claude stale command"
assert_contains "$stale_check_out" "config=~/.claude/settings.json event=Stop matcher=<none>" "stale hook check: names Claude config/event/matcher"
assert_contains "$stale_check_out" "command_path=${STALE_HOOK_HOME}/.vibeguard/installed/hooks/session-tagger.sh" "stale hook check: names missing installed hook path"
assert_contains "$stale_check_out" "stale Codex hook command" "stale hook check: reports Codex stale command"
assert_contains "$stale_check_out" "config=~/.codex/hooks.json event=Stop matcher=<none>" "stale hook check: names Codex config/event/matcher"
assert_contains "$stale_check_out" "repair=bash setup.sh --yes" "stale hook check: names repair action"

stale_install_check_out="$(HOME="${STALE_HOOK_HOME}" bash "${SETUP_SCRIPT}" --check --install 2>&1)"
stale_install_check_rc=$?
assert_eq "$stale_install_check_rc" "2" "install check: broken required state exits 2"
assert_contains "$stale_install_check_out" "stale Codex hook command" "install check: reports broken required hook state"

HOME="${STALE_HOOK_HOME}" python3 "${REPO_DIR}/scripts/lib/settings_json.py" upsert-vibeguard \
  --settings-file "${STALE_HOOK_HOME}/.claude/settings.json" \
  --repo-dir "${REPO_DIR}" \
  --profile core >/dev/null
HOME="${STALE_HOOK_HOME}" python3 "${REPO_DIR}/scripts/lib/codex_hooks_json.py" upsert-vibeguard \
  --hooks-file "${STALE_HOOK_HOME}/.codex/hooks.json" \
  --wrapper "${STALE_HOOK_HOME}/.vibeguard/run-hook-codex.sh" >/dev/null
assert_cmd "stale hook repair: Claude installed hook path removed" bash -c "! grep -q '.vibeguard/installed/hooks/session-tagger.sh' '${STALE_HOOK_HOME}/.claude/settings.json'"
assert_cmd "stale hook repair: Codex installed hook path removed" bash -c "! grep -q '.vibeguard/installed/hooks/session-tagger.sh' '${STALE_HOOK_HOME}/.codex/hooks.json'"
assert_cmd "stale hook repair: Claude stale check passes" env HOME="${STALE_HOOK_HOME}" python3 "${REPO_DIR}/scripts/lib/settings_json.py" check-stale-hooks --settings-file "${STALE_HOOK_HOME}/.claude/settings.json"
assert_cmd "stale hook repair: Codex stale check passes" env HOME="${STALE_HOOK_HOME}" python3 "${REPO_DIR}/scripts/lib/codex_hooks_json.py" check-stale-hooks --hooks-file "${STALE_HOOK_HOME}/.codex/hooks.json"

# --- Backwards-compat exit code contract ---
header "exit code contract"
# Default mode must keep exiting 0 even on a broken install, so existing
# callers (tests/test_setup.sh, downstream CI scripts) do not regress.
bash "${SETUP_SCRIPT}" --check >/dev/null 2>&1
default_rc=$?
assert_eq "$default_rc" "0" "default mode: exit 0 regardless of health (compat)"

# --no-summary must also keep exiting 0.
bash "${SETUP_SCRIPT}" --check --no-summary >/dev/null 2>&1
no_sum_rc=$?
assert_eq "$no_sum_rc" "0" "no-summary mode: exit 0 (compat)"

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

# --- Summary ---
printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
  printf '\033[32mAll %d/%d tests passed\033[0m\n' "$PASS" "$TOTAL"
  exit 0
else
  printf '\033[31m%d/%d tests failed\033[0m\n' "$FAIL" "$TOTAL"
  exit 1
fi
