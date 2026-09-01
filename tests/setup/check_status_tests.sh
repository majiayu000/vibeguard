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
UNMANAGED_HOOK_HOME=""
TIMEOUT_HOOK_HOME=""
BROKEN_HOME=""
PROJECT_HOOK_HOME=""
PROJECT_HOOK_REPO=""
STALE_RUNTIME_DIR=""
SYSTEMD_CHECK_HOME=""
INVALID_DISABLED_SKILLS_HOME=""
INVALID_QUARANTINE_STATE_HOME=""
PROTECTION_STATUS_HOME=""
PROTECTION_EMPTY_HOME=""

cleanup() {
  if [[ -n "${AWK_PORTABILITY_FIXTURE}" ]]; then
    rm -f "${AWK_PORTABILITY_FIXTURE}"
  fi
  if [[ -n "${STALE_HOOK_HOME}" ]]; then
    rm -rf "${STALE_HOOK_HOME}"
  fi
  if [[ -n "${UNMANAGED_HOOK_HOME}" ]]; then
    rm -rf "${UNMANAGED_HOOK_HOME}"
  fi
  if [[ -n "${TIMEOUT_HOOK_HOME}" ]]; then
    rm -rf "${TIMEOUT_HOOK_HOME}"
  fi
  if [[ -n "${BROKEN_HOME}" ]]; then
    rm -rf "${BROKEN_HOME}"
  fi
  if [[ -n "${PROJECT_HOOK_HOME}" ]]; then
    rm -rf "${PROJECT_HOOK_HOME}"
  fi
  if [[ -n "${PROJECT_HOOK_REPO}" ]]; then
    rm -rf "${PROJECT_HOOK_REPO}"
  fi
  if [[ -n "${STALE_RUNTIME_DIR}" ]]; then
    rm -rf "${STALE_RUNTIME_DIR}"
  fi
  if [[ -n "${SYSTEMD_CHECK_HOME}" ]]; then
    rm -rf "${SYSTEMD_CHECK_HOME}"
  fi
  if [[ -n "${INVALID_DISABLED_SKILLS_HOME}" ]]; then
    rm -rf "${INVALID_DISABLED_SKILLS_HOME}"
  fi
  if [[ -n "${INVALID_QUARANTINE_STATE_HOME}" ]]; then
    rm -rf "${INVALID_QUARANTINE_STATE_HOME}"
  fi
  if [[ -n "${PROTECTION_STATUS_HOME}" ]]; then
    rm -rf "${PROTECTION_STATUS_HOME}"
  fi
  if [[ -n "${PROTECTION_EMPTY_HOME}" ]]; then
    rm -rf "${PROTECTION_EMPTY_HOME}"
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
  if grep -qF -- "$expected" <<< "$output"; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" forbidden="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qF -- "$forbidden" <<< "$output"; then
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

# Establish one current-source runtime before any setup behavior invocation.
# The hostile fixture proves that protection-status rejects a same-version
# runtime that predates its event query before setup behavior can invoke it.
STALE_RUNTIME_DIR="$(mktemp -d)"
STALE_RUNTIME="${STALE_RUNTIME_DIR}/vibeguard-runtime"
STALE_RUNTIME_MARKER="${STALE_RUNTIME_DIR}/called"
CURRENT_RUNTIME_VERSION="$(tr -d '[:space:]' < "${REPO_DIR}/vibeguard-runtime/VERSION")"
cat > "${STALE_RUNTIME}" <<'SH'
#!/usr/bin/env bash
if [[ -n "${VIBEGUARD_STALE_RUNTIME_MARKER:-}" ]]; then
  printf '%s\n' "${1:-<none>}" >> "${VIBEGUARD_STALE_RUNTIME_MARKER}"
fi
case "${1:-}" in
  version) printf '%s\n' "${VIBEGUARD_STALE_RUNTIME_VERSION:?}" ;;
  setup-state-capabilities) printf '%s\n' 'complete-snapshot-v2' ;;
  latest-client-events)
    printf '%s\n' "Unknown command: latest-client-events" >&2
    exit 2
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "${STALE_RUNTIME}"

if env \
  VIBEGUARD_REPO_DIR="${REPO_DIR}" \
  VIBEGUARD_SETUP_RUNTIME_VERSION="${CURRENT_RUNTIME_VERSION}" \
  VIBEGUARD_STALE_RUNTIME_MARKER= \
  VIBEGUARD_STALE_RUNTIME_VERSION="${CURRENT_RUNTIME_VERSION}" \
  bash -c 'source "$1"; setup_runtime_supports "$2"' \
    _ "${REPO_DIR}/scripts/setup/lib.sh" "${STALE_RUNTIME}"; then
  printf 'ERROR: stale runtime fixture unexpectedly satisfied the exact capability probe\n' >&2
  exit 1
fi
rm -f "${STALE_RUNTIME_MARKER}"

export VIBEGUARD_SETUP_RUNTIME="${STALE_RUNTIME}"
export VIBEGUARD_SETUP_SKIP_REPO_RUNTIME=1
export VIBEGUARD_SETUP_RUNTIME_VERSION="hostile-version"
export CARGO_TARGET_DIR="${STALE_RUNTIME_DIR}/external-target"
export CARGO_BUILD_TARGET="invalid-host-target"
export VIBEGUARD_STALE_RUNTIME_MARKER="${STALE_RUNTIME_MARKER}"
export VIBEGUARD_STALE_RUNTIME_VERSION="${CURRENT_RUNTIME_VERSION}"

unset CARGO_BUILD_TARGET
unset VIBEGUARD_SETUP_RUNTIME_VERSION
export VIBEGUARD_SETUP_SKIP_REPO_RUNTIME=0
CURRENT_SETUP_RUNTIME="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
TOTAL=$((TOTAL + 1))
if cargo build \
  --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" \
  --target-dir "${REPO_DIR}/vibeguard-runtime/target"; then
  green "runtime config setup fixture builds current runtime"
  PASS=$((PASS + 1))
else
  red "runtime config setup fixture failed to build current worktree runtime"
  FAIL=$((FAIL + 1))
  exit 1
fi
if [[ ! -x "${CURRENT_SETUP_RUNTIME}" ]]; then
  printf 'ERROR: current setup runtime is not executable: %s\n' \
    "${CURRENT_SETUP_RUNTIME}" >&2
  exit 1
fi
export VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}"

# --- Syntax checks ---
header "syntax"
assert_cmd "setup.sh syntax" bash -n "${SETUP_SCRIPT}"
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
assert_contains "$deg_summary" "first: something optional" "degraded: verdict names the first issue"
deg_rc="$(run_with_buffer "$degraded_buf" 'status_exit_code')"
assert_eq "$deg_rc" "1" "degraded: exit code 1"

# Broken — has [BROKEN] / [FAIL] / [MISSING].
broken_buf=$'[OK] foo\n[BROKEN] hook wrapper missing\n[MISSING] runtime binary\n[FAIL] schema invalid\n'
broken_summary="$(run_with_buffer "$broken_buf" 'status_print_summary')"
assert_contains "$broken_summary" "BROKEN  : 1"  "broken: broken count"
assert_contains "$broken_summary" "FAIL    : 1"  "broken: fail count"
assert_contains "$broken_summary" "MISSING : 1"  "broken: missing count"
assert_contains "$broken_summary" "BROKEN"       "broken: verdict is BROKEN"
assert_contains "$broken_summary" "first: hook wrapper missing" "broken: verdict names the first required issue"
broken_rc="$(run_with_buffer "$broken_buf" 'status_exit_code')"
assert_eq "$broken_rc" "2" "broken: exit code 2"

# Drift — stale managed content must require repair, including install checks.
drift_buf=$'[OK] base\n[DRIFT] managed VibeGuard block differs from current rules\n'
drift_summary="$(run_with_buffer "$drift_buf" 'status_print_summary')"
assert_contains "$drift_summary" "DRIFT   : 1" "drift: drift count"
assert_contains "$drift_summary" "BROKEN" "drift: verdict is BROKEN"
drift_rc="$(run_with_buffer "$drift_buf" 'status_exit_code')"
assert_eq "$drift_rc" "2" "drift: strict exit code 2"
drift_install_rc="$(run_with_buffer "$drift_buf" 'status_install_exit_code')"
assert_eq "$drift_install_rc" "2" "drift: install exit code 2"

PROFILE="minimal"
managed_skill_missing_buf=$'[OK] base\n[MISSING] eval-harness skill not in ~/.claude/skills/\n[MISSING] iterative-retrieval skill not in ~/.claude/skills/\n'
managed_skill_missing_summary="$(run_with_buffer "$managed_skill_missing_buf" 'status_print_summary')"
assert_contains "$managed_skill_missing_summary" "BROKEN" "minimal profile: missing installed skills is broken"
assert_contains "$managed_skill_missing_summary" "first: eval-harness skill not in ~/.claude/skills/" "missing installed skill: verdict names the first issue"
managed_skill_missing_rc="$(run_with_buffer "$managed_skill_missing_buf" 'status_exit_code')"
assert_eq "$managed_skill_missing_rc" "2" "minimal profile: missing installed skills fails strict check"
managed_skill_install_rc="$(run_with_buffer "$managed_skill_missing_buf" 'status_install_exit_code')"
assert_eq "$managed_skill_install_rc" "2" "minimal install mode: missing installed skills fails"
managed_assets_missing_buf=$'[OK] base\n[MISSING] 1/2 VibeGuard agent(s) missing in ~/.claude/agents/: reviewer.md\n[MISSING] context profiles not in ~/.claude/context-profiles/\n'
managed_assets_install_rc="$(run_with_buffer "$managed_assets_missing_buf" 'status_install_exit_code')"
assert_eq "$managed_assets_install_rc" "2" "minimal install mode: missing installed agents/profiles fails"
PROFILE="core"
core_skill_install_rc="$(run_with_buffer "$managed_skill_missing_buf" 'status_install_exit_code')"
assert_eq "$core_skill_install_rc" "2" "core install mode: missing required skills fail"
core_integration_install_rc="$(run_with_buffer "$managed_assets_missing_buf" 'status_install_exit_code')"
assert_eq "$core_integration_install_rc" "2" "core install mode: missing required agents/profiles fail"
recovery_missing_buf=$'[OK] installed runtime active\n[WARN] Runtime recovery source missing: current protection can still run, but repair and uninstall recovery are unavailable (run: bash setup.sh --yes)\n'
recovery_missing_summary="$(run_with_buffer "$recovery_missing_buf" 'status_print_summary')"
assert_contains "$recovery_missing_summary" "DEGRADED" "recovery missing: human verdict is degraded"
assert_contains "$recovery_missing_summary" "first: Runtime recovery source missing" "recovery missing: verdict names the recovery gap"
recovery_install_rc="$(run_with_buffer "$recovery_missing_buf" 'status_install_exit_code')"
assert_eq "$recovery_install_rc" "2" "recovery missing: install verification still fails"
codex_required_missing_buf=$'[OK] base\n[MISSING] Codex hooks.json not installed\n[MISSING] Codex hook wrapper not installed\n[MISSING] hooks feature not enabled in ~/.codex/config.toml\n'
codex_required_install_rc="$(run_with_buffer "$codex_required_missing_buf" 'status_install_exit_code')"
assert_eq "$codex_required_install_rc" "2" "install mode: Codex missing rows fail"
codex_skill_missing_buf=$'[OK] base\n[MISSING] vibeguard skill not in ~/.codex/skills/\n'
codex_skill_install_rc="$(run_with_buffer "$codex_skill_missing_buf" 'status_install_exit_code')"
assert_eq "$codex_skill_install_rc" "2" "install mode: Codex skill missing rows fail"
required_missing_buf=$'[OK] base\n[MISSING] vibeguard-runtime runtime binary (~/.vibeguard/installed/bin/vibeguard-runtime)\n'
required_install_rc="$(run_with_buffer "$required_missing_buf" 'status_install_exit_code')"
assert_eq "$required_install_rc" "2" "install mode: required missing rows still fail"

# [INFO] is neutral and never affects the verdict.
info_buf=$'[OK] up\n[INFO] optional module not configured\n'
info_summary="$(run_with_buffer "$info_buf" 'status_print_summary')"
assert_contains "$info_summary" "INFO    : 1"  "info: info count"
assert_contains "$info_summary" "HEALTHY"      "info: verdict still HEALTHY"
info_rc="$(run_with_buffer "$info_buf" 'status_exit_code')"
assert_eq "$info_rc" "0" "info: exit code 0"

# [DISABLED] is an intentional, neutral state that remains visible in summaries
# and JSON without appearing in quiet-mode problem output.
disabled_buf=$'[OK] base\n[DISABLED] plan-flow skill disabled in ~/.vibeguard/config.json\n'
disabled_summary="$(run_with_buffer "$disabled_buf" 'status_print_summary')"
assert_contains "$disabled_summary" "DISABLED: 1" "disabled: count"
assert_contains "$disabled_summary" "HEALTHY" "disabled: verdict still HEALTHY"
disabled_rc="$(run_with_buffer "$disabled_buf" 'status_exit_code')"
assert_eq "$disabled_rc" "0" "disabled: exit code 0"

# --- Quiet-mode problem filter ---
header "status_report quiet filter"
quiet_out="$(run_with_buffer "$broken_buf" 'status_print_summary --quiet')"
assert_contains "$quiet_out" "Problems"            "quiet: shows Problems header"
assert_contains "$quiet_out" "[BROKEN]"            "quiet: includes BROKEN row"
assert_contains "$quiet_out" "[MISSING]"           "quiet: includes MISSING row"
assert_contains "$quiet_out" "[FAIL]"              "quiet: includes FAIL row"
assert_not_contains "$quiet_out" "[OK] foo"        "quiet: drops OK rows"
quiet_drift="$(run_with_buffer "$drift_buf" 'status_print_summary --quiet')"
assert_contains "$quiet_drift" "Problems"          "quiet+drift: shows Problems header"
assert_contains "$quiet_drift" "[DRIFT]"           "quiet+drift: includes DRIFT row"

# Healthy + quiet → no Problems block.
quiet_healthy="$(run_with_buffer "$healthy_buf" 'status_print_summary --quiet')"
assert_not_contains "$quiet_healthy" "Problems"    "quiet+healthy: no Problems block"
quiet_disabled="$(run_with_buffer "$disabled_buf" 'status_print_summary --quiet')"
assert_not_contains "$quiet_disabled" "Problems" "quiet+disabled: no Problems block"

# --- JSON shape ---
header "status_report JSON output"
json_out="$(run_with_buffer "$broken_buf" 'status_emit_json')"
# Parse-driven assertions so we do not depend on key ordering or
# whitespace style of the chosen JSON encoder.
assert_json_path "$json_out" 'd["schema_version"]' "1"      "json: schema_version=1"
assert_json_path "$json_out" 'd["verdict"]'        "broken" "json: verdict=broken"
assert_json_path "$json_out" 'd["counts"]["broken"]'  "1"   "json: counts.broken=1"
assert_json_path "$json_out" 'd["counts"]["missing"]' "1"   "json: counts.missing=1"
assert_json_path "$json_out" 'd["counts"]["drift"]'   "0"   "json: counts.drift=0"
assert_json_path "$json_out" 'd["counts"]["fail"]'    "1"   "json: counts.fail=1"
assert_json_path "$json_out" 'd["counts"]["ok"]'      "1"   "json: counts.ok=1"
assert_json_path "$json_out" 'len(d["events"])'       "4"   "json: 4 events captured"
assert_json_path "$json_out" 'sorted({e["level"] for e in d["events"]})' "['BROKEN', 'FAIL', 'MISSING', 'OK']" "json: event levels"
drift_json="$(run_with_buffer "$drift_buf" 'status_emit_json')"
assert_json_path "$drift_json" 'd["counts"]["drift"]' "1" "json: drift count"
assert_json_path "$drift_json" 'd["verdict"]' "broken" "json: drift verdict"
assert_json_path "$drift_json" 'd["events"][1]["level"]' "DRIFT" "json: drift event level"
disabled_json="$(run_with_buffer "$disabled_buf" 'status_emit_json')"
assert_json_path "$disabled_json" 'd["counts"]["disabled"]' "1" "json: disabled count"
assert_json_path "$disabled_json" 'd["verdict"]' "healthy" "json: disabled verdict"
assert_json_path "$disabled_json" 'd["events"][1]["level"]' "DISABLED" "json: disabled event level"
PROFILE="minimal"
managed_skill_missing_json="$(run_with_buffer "$managed_skill_missing_buf" 'status_emit_json')"
assert_json_path "$managed_skill_missing_json" 'd["verdict"]' "broken" "json: missing installed skill verdict is broken"

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

spoof_buf=$'[WARN] stale snapshot: [OK]\nfree-form note [BROKEN]\n'
spoof_summary="$(run_with_buffer "$spoof_buf" 'status_print_summary')"
assert_contains "$spoof_summary" "OK      : 0" "status parser: embedded OK marker does not override line prefix"
assert_contains "$spoof_summary" "WARN    : 1" "status parser: warning prefix wins over embedded marker"
assert_contains "$spoof_summary" "BROKEN  : 0" "status parser: embedded BROKEN marker in untagged line ignored"
spoof_json="$(run_with_buffer "$spoof_buf" 'status_emit_json')"
assert_json_path "$spoof_json" 'd["counts"]["warn"]' "1" "json: embedded OK marker still counts as warn"
assert_json_path "$spoof_json" 'd["events"][0]["level"]' "WARN" "json: embedded status marker cannot spoof level"
assert_json_path "$spoof_json" 'len(d["events"])' "1" "json: unprefixed embedded marker ignored"

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

# Top-level help should advertise the human/machine command split.
top_help_out="$(bash "${SETUP_SCRIPT}" --help 2>&1)"
top_help_rc=$?
assert_eq "$top_help_rc" "0" "setup --help: exit 0"
assert_contains "$top_help_out" "doctor" "setup --help: documents doctor"
assert_contains "$top_help_out" "verify-install" "setup --help: documents verify-install"
assert_contains "$top_help_out" "verify-project --json" "setup --help: documents JSON verify route"
assert_contains "$top_help_out" "protection-status" "setup --help: documents truthful protection status"
assert_contains "$top_help_out" "setup.sh --check --install  -> bash setup.sh verify-install" "setup --help: documents install migration"

header "truthful protection status"
PROTECTION_STATUS_HOME="$(mktemp -d)"
PROTECTION_BIN="${PROTECTION_STATUS_HOME}/bin"
PROTECTION_LOG_ROOT="${PROTECTION_STATUS_HOME}/logs"
PROTECTION_PROJECT_LOG="${PROTECTION_LOG_ROOT}/projects/current-project"
PROTECTION_OTHER_LOG="${PROTECTION_LOG_ROOT}/projects/other-project"
mkdir -p \
  "${PROTECTION_STATUS_HOME}/.claude" \
  "${PROTECTION_STATUS_HOME}/.codex" \
  "${PROTECTION_STATUS_HOME}/.gemini" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/installed/bin" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/installed/hooks" \
  "${PROTECTION_BIN}" \
  "${PROTECTION_PROJECT_LOG}" \
  "${PROTECTION_OTHER_LOG}"
for wrapper in run-hook.sh run-hook-codex.sh run-hook-gemini.sh; do
  cp "${REPO_DIR}/hooks/${wrapper}" \
    "${PROTECTION_STATUS_HOME}/.vibeguard/${wrapper}"
  chmod +x "${PROTECTION_STATUS_HOME}/.vibeguard/${wrapper}"
done
printf '%s\n' '#!/usr/bin/env bash' '[[ "${1:-}" == "hooks" && "${2:-}" == "--help" ]]' \
  > "${PROTECTION_BIN}/gemini"
chmod +x "${PROTECTION_BIN}/gemini"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  > "${PROTECTION_STATUS_HOME}/.vibeguard/installed/hooks/pre-bash-guard.sh"
chmod +x "${PROTECTION_STATUS_HOME}/.vibeguard/installed/hooks/pre-bash-guard.sh"
cp "${REPO_DIR}"/hooks/*.sh \
  "${PROTECTION_STATUS_HOME}/.vibeguard/installed/hooks/"
cp -R "${REPO_DIR}/hooks/_lib" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/installed/hooks/_lib"
cp "${CURRENT_SETUP_RUNTIME}" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/installed/bin/vibeguard-runtime"
chmod +x "${PROTECTION_STATUS_HOME}/.vibeguard/installed/bin/vibeguard-runtime"
printf '%s\n' 'gemini-cli-hooks-v1' \
  > "${PROTECTION_STATUS_HOME}/.vibeguard/gemini-enabled"

HOME="${PROTECTION_STATUS_HOME}" "${CURRENT_SETUP_RUNTIME}" \
  setup-settings-upsert "${REPO_DIR}" \
  "${PROTECTION_STATUS_HOME}/.claude/settings.json" core >/dev/null
HOME="${PROTECTION_STATUS_HOME}" "${CURRENT_SETUP_RUNTIME}" \
  setup-codex-hooks-upsert "${REPO_DIR}" \
  "${PROTECTION_STATUS_HOME}/.codex/hooks.json" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/run-hook-codex.sh" core >/dev/null
HOME="${PROTECTION_STATUS_HOME}" "${CURRENT_SETUP_RUNTIME}" \
  setup-codex-config-enable-hooks \
  "${PROTECTION_STATUS_HOME}/.codex/config.toml" >/dev/null
HOME="${PROTECTION_STATUS_HOME}" "${CURRENT_SETUP_RUNTIME}" \
  setup-gemini-hooks-upsert \
  "${PROTECTION_STATUS_HOME}/.gemini/settings.json" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/run-hook-gemini.sh" >/dev/null

printf '%s' "${REPO_DIR}" > "${PROTECTION_PROJECT_LOG}/.project-root"
printf '%s' "${PROTECTION_STATUS_HOME}/other-repo" \
  > "${PROTECTION_OTHER_LOG}/.project-root"
cat > "${PROTECTION_PROJECT_LOG}/events.jsonl" <<'JSONL'
{"ts":"2026-08-31T01:00:00Z","client":"claude","hook":"pre-bash-guard","decision":"pass"}
{"ts":"2026-08-31T01:01:00Z","client":"codex","hook":"pre-write-guard","decision":"block"}
JSONL
cat > "${PROTECTION_OTHER_LOG}/events.jsonl" <<'JSONL'
{"ts":"2030-01-01T00:00:00Z","client":"gemini","hook":"pre-bash-guard","decision":"pass"}
JSONL

protection_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${REPO_DIR}"
)"
assert_contains "${protection_out}" "Project: ${REPO_DIR}" \
  "protection status names the checked project"
assert_contains "${protection_out}" "Claude Code: PROTECTED" \
  "Claude requires canonical config and current-project evidence"
assert_contains "${protection_out}" "Codex CLI: PROTECTED" \
  "Codex requires canonical config and current-project evidence"
assert_contains "${protection_out}" "Gemini CLI: DEGRADED" \
  "Gemini config without current-project evidence is degraded"
assert_contains "${protection_out}" \
  "No Gemini CLI hook event has been observed for this project" \
  "degraded Gemini status explains the missing evidence"
assert_not_contains "${protection_out}" "2030-01-01T00:00:00Z" \
  "protection status never substitutes another project's event"

PROTECTION_PROJECT_HASH="$(printf '%s' "${REPO_DIR}" | shasum -a 256 | cut -c1-8)"
PROTECTION_HASH_LOG="${PROTECTION_LOG_ROOT}/projects/${PROTECTION_PROJECT_HASH}"
mkdir -p "${PROTECTION_HASH_LOG}"
cp "${PROTECTION_PROJECT_LOG}/events.jsonl" "${PROTECTION_HASH_LOG}/events.jsonl"
rm -f "${PROTECTION_PROJECT_LOG}/.project-root"
hash_fallback_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${REPO_DIR}"
)"
assert_contains "${hash_fallback_out}" "Claude Code: PROTECTED" \
  "missing project marker falls back to the deterministic project log"
printf '%s' "${REPO_DIR}" > "${PROTECTION_PROJECT_LOG}/.project-root"

printf '%s\n' \
  '{"ts":"2026-08-31T01:02:00Z","client":"gemini","hook":"pre-bash-guard","decision":"pass"}' \
  >> "${PROTECTION_PROJECT_LOG}/events.jsonl"
gemini_protected_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${REPO_DIR}"
)"
assert_contains "${gemini_protected_out}" "Gemini CLI: PROTECTED" \
  "Gemini becomes protected only after current-project evidence"
assert_contains "${gemini_protected_out}" \
  "2026-08-31T01:02:00Z | pre-bash-guard | pass" \
  "protected Gemini status names its live evidence"

mv "${PROTECTION_STATUS_HOME}/.vibeguard/installed/bin/vibeguard-runtime" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/installed/bin/vibeguard-runtime.missing"
missing_runtime_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${REPO_DIR}"
)"
assert_contains "${missing_runtime_out}" "Claude Code: DEGRADED" \
  "a missing installed runtime degrades Claude protection"
assert_contains "${missing_runtime_out}" "Codex CLI: DEGRADED" \
  "a missing installed runtime degrades Codex protection"
assert_contains "${missing_runtime_out}" "Gemini CLI: DEGRADED" \
  "a missing installed runtime degrades Gemini protection"
assert_contains "${missing_runtime_out}" "installed runtime" \
  "missing installed runtime is explained"
mv "${PROTECTION_STATUS_HOME}/.vibeguard/installed/bin/vibeguard-runtime.missing" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/installed/bin/vibeguard-runtime"

cp "${PROTECTION_STATUS_HOME}/.vibeguard/run-hook.sh" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/run-hook.sh.canonical"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  > "${PROTECTION_STATUS_HOME}/.vibeguard/run-hook.sh"
chmod +x "${PROTECTION_STATUS_HOME}/.vibeguard/run-hook.sh"
wrapper_drift_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${REPO_DIR}"
)"
assert_contains "${wrapper_drift_out}" "Claude Code: DEGRADED" \
  "an executable no-op Claude wrapper cannot report protected"
assert_contains "${wrapper_drift_out}" "Gemini CLI: DEGRADED" \
  "Gemini cannot report protected through a drifted shared wrapper"
mv "${PROTECTION_STATUS_HOME}/.vibeguard/run-hook.sh.canonical" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/run-hook.sh"

cp "${PROTECTION_STATUS_HOME}/.claude/settings.json" \
  "${PROTECTION_STATUS_HOME}/.claude/settings.json.canonical"
python3 - "${PROTECTION_STATUS_HOME}/.claude/settings.json" \
  "${PROTECTION_STATUS_HOME}" <<'PY'
import sys
from pathlib import Path

settings = Path(sys.argv[1])
home = sys.argv[2]
text = settings.read_text(encoding="utf-8")
text = text.replace(
    f"bash {home}/.vibeguard/run-hook.sh ",
    f"bash {home}/.vibeguard/installed/hooks/",
)
settings.write_text(text, encoding="utf-8")
PY
direct_claude_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${REPO_DIR}"
)"
assert_contains "${direct_claude_out}" "Claude Code: DEGRADED" \
  "direct Claude hook scripts cannot bypass the canonical wrapper verdict"
mv "${PROTECTION_STATUS_HOME}/.claude/settings.json.canonical" \
  "${PROTECTION_STATUS_HOME}/.claude/settings.json"

cp "${PROTECTION_PROJECT_LOG}/events.jsonl" \
  "${PROTECTION_PROJECT_LOG}/events.jsonl.valid"
printf '%s\n' '{' >> "${PROTECTION_PROJECT_LOG}/events.jsonl"
malformed_evidence_rc=0
malformed_evidence_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${REPO_DIR}" 2>&1
)" || malformed_evidence_rc=$?
assert_cmd "malformed project evidence fails protection status" \
  test "${malformed_evidence_rc}" -ne 0
assert_contains "${malformed_evidence_out}" "failed to read project event evidence" \
  "malformed project evidence fails visibly"
mv "${PROTECTION_PROJECT_LOG}/events.jsonl.valid" \
  "${PROTECTION_PROJECT_LOG}/events.jsonl"

rm -f "${PROTECTION_STATUS_HOME}/.vibeguard/gemini-enabled"
gemini_marker_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${REPO_DIR}"
)"
assert_contains "${gemini_marker_out}" "Gemini CLI: DEGRADED" \
  "active Gemini settings without ownership marker are degraded"
assert_not_contains "${gemini_marker_out}" "Gemini CLI: UNPROTECTED" \
  "active Gemini settings are still detected without the marker"
printf '%s\n' 'gemini-cli-hooks-v1' \
  > "${PROTECTION_STATUS_HOME}/.vibeguard/gemini-enabled"

mv "${PROTECTION_STATUS_HOME}/.vibeguard/installed/hooks/pre-write-guard.sh" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/installed/hooks/pre-write-guard.sh.missing"
missing_asset_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${REPO_DIR}"
)"
assert_contains "${missing_asset_out}" "Claude Code: DEGRADED" \
  "a missing profile hook asset degrades Claude protection"
assert_contains "${missing_asset_out}" "Codex CLI: DEGRADED" \
  "a missing profile hook asset degrades Codex protection"
mv "${PROTECTION_STATUS_HOME}/.vibeguard/installed/hooks/pre-write-guard.sh.missing" \
  "${PROTECTION_STATUS_HOME}/.vibeguard/installed/hooks/pre-write-guard.sh"

PROTECTION_POLICY_PROJECT="${PROTECTION_STATUS_HOME}/policy-project"
PROTECTION_POLICY_LOG="${PROTECTION_LOG_ROOT}/projects/policy-project"
mkdir -p "${PROTECTION_POLICY_PROJECT}" "${PROTECTION_POLICY_LOG}"
git -C "${PROTECTION_POLICY_PROJECT}" init -q
printf '%s\n' '{"enforcement":"off"}' \
  > "${PROTECTION_POLICY_PROJECT}/.vibeguard.json"
printf '%s' "${PROTECTION_POLICY_PROJECT}" \
  > "${PROTECTION_POLICY_LOG}/.project-root"
cat > "${PROTECTION_POLICY_LOG}/events.jsonl" <<'JSONL'
{"ts":"2026-08-31T02:00:00Z","client":"claude","hook":"pre-bash-guard","decision":"pass"}
{"ts":"2026-08-31T02:01:00Z","client":"codex","hook":"pre-write-guard","decision":"pass"}
{"ts":"2026-08-31T02:02:00Z","client":"gemini","hook":"pre-edit-guard","decision":"pass"}
JSONL
policy_off_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${PROTECTION_POLICY_PROJECT}"
)"
assert_contains "${policy_off_out}" "Claude Code: DEGRADED" \
  "project enforcement off degrades Claude protection"
assert_contains "${policy_off_out}" "Codex CLI: DEGRADED" \
  "project enforcement off degrades Codex protection"
assert_contains "${policy_off_out}" "Gemini CLI: DEGRADED" \
  "project enforcement off degrades Gemini protection"
assert_contains "${policy_off_out}" "Project policy" \
  "policy degradation is explained"

PROTECTION_FULL_PROJECT="${PROTECTION_STATUS_HOME}/full-profile-project"
PROTECTION_FULL_LOG="${PROTECTION_LOG_ROOT}/projects/full-profile-project"
mkdir -p "${PROTECTION_FULL_PROJECT}" "${PROTECTION_FULL_LOG}"
git -C "${PROTECTION_FULL_PROJECT}" init -q
printf '%s\n' '{"profile":"full"}' \
  > "${PROTECTION_FULL_PROJECT}/.vibeguard.json"
printf '%s' "${PROTECTION_FULL_PROJECT}" \
  > "${PROTECTION_FULL_LOG}/.project-root"
cat > "${PROTECTION_FULL_LOG}/events.jsonl" <<'JSONL'
{"ts":"2026-08-31T03:00:00Z","client":"claude","hook":"pre-bash-guard","decision":"pass"}
{"ts":"2026-08-31T03:01:00Z","client":"codex","hook":"pre-write-guard","decision":"pass"}
JSONL
full_profile_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${PROTECTION_FULL_PROJECT}"
)"
assert_contains "${full_profile_out}" "Claude Code: DEGRADED" \
  "a full project profile cannot report protected through a core Claude install"
assert_contains "${full_profile_out}" "Codex CLI: DEGRADED" \
  "a full project profile cannot report protected through a core Codex install"
assert_contains "${full_profile_out}" "Project profile full requires" \
  "stronger project profile degradation is explained"

printf '%s\n' '[features]' 'hooks = false' \
  > "${PROTECTION_STATUS_HOME}/.codex/config.toml"
codex_degraded_out="$(
  HOME="${PROTECTION_STATUS_HOME}" \
  PATH="${PROTECTION_BIN}:${PATH}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_LOG_ROOT}" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${REPO_DIR}"
)"
assert_contains "${codex_degraded_out}" "Codex CLI: DEGRADED" \
  "Codex historical evidence cannot hide current configuration drift"
assert_contains "${codex_degraded_out}" \
  "The installed integration is incomplete or non-canonical" \
  "degraded Codex status explains configuration drift"

PROTECTION_EMPTY_HOME="$(mktemp -d)"
mkdir -p \
  "${PROTECTION_EMPTY_HOME}/.claude" \
  "${PROTECTION_EMPTY_HOME}/.codex" \
  "${PROTECTION_EMPTY_HOME}/.gemini"
printf '%s\n' '{}' > "${PROTECTION_EMPTY_HOME}/.claude/settings.json"
printf '%s\n' 'model = "gpt-5"' > "${PROTECTION_EMPTY_HOME}/.codex/config.toml"
printf '%s\n' '{}' > "${PROTECTION_EMPTY_HOME}/.gemini/settings.json"
empty_protection_out="$(
  HOME="${PROTECTION_EMPTY_HOME}" \
  VIBEGUARD_LOG_DIR="${PROTECTION_EMPTY_HOME}/logs" \
  VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" protection-status "${REPO_DIR}"
)"
assert_contains "${empty_protection_out}" "Claude Code: UNPROTECTED" \
  "missing Claude integration is unprotected"
assert_contains "${empty_protection_out}" "Codex CLI: UNPROTECTED" \
  "missing Codex integration is unprotected"
assert_contains "${empty_protection_out}" "Gemini CLI: UNPROTECTED" \
  "disabled Gemini integration is unprotected"
assert_contains "${empty_protection_out}" \
  "bash ${REPO_DIR}/setup.sh --yes --host gemini --profile core" \
  "unprotected Gemini status gives one runnable profile-preserving action"

# Help should exit 0 and print usage.
help_out="$(bash "${SETUP_SCRIPT}" --check --help 2>&1)"
help_rc=$?
assert_eq "$help_rc" "0" "check --help: exit 0"
assert_contains "$help_out" "Usage: setup.sh --check" "check --help: prints usage"
assert_contains "$help_out" "Exit codes"             "check --help: documents exit codes"
assert_contains "$help_out" "--install"              "check --help: documents install verification mode"
assert_contains "$help_out" "setup.sh doctor"        "check --help: documents doctor command"
assert_contains "$help_out" "setup.sh verify-install" "check --help: documents verify-install command"
assert_contains "$help_out" "setup.sh --check --json     -> setup.sh verify-project --json" "check --help: documents json migration"

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

doctor_out="$(bash "${SETUP_SCRIPT}" doctor 2>&1 || true)"
assert_contains "$doctor_out" "VibeGuard Installation Status" "doctor: legacy header preserved"
assert_contains "$doctor_out" "Summary" "doctor: summary block present"

BROKEN_HOME="$(mktemp -d)"
broken_runtime_out="$(HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" --check 2>&1 || true)"
assert_contains "$broken_runtime_out" \
  "Runtime recovery source missing: installed runtime is unavailable; repair is required" \
  "missing runtimes: recovery warning requires repair"
assert_not_contains "$broken_runtime_out" \
  "Runtime recovery source missing: current protection can still run" \
  "missing runtimes: recovery warning does not claim protection can run"

mkdir -p "${BROKEN_HOME}/.vibeguard/installed/bin"
cat > "${BROKEN_HOME}/.vibeguard/installed/bin/vibeguard-runtime" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "${BROKEN_HOME}/.vibeguard/installed/bin/vibeguard-runtime"
broken_executable_runtime_out="$(HOME="${BROKEN_HOME}" bash "${SETUP_SCRIPT}" --check 2>&1 || true)"
assert_contains "$broken_executable_runtime_out" \
  "Runtime recovery source missing: installed runtime is unavailable; repair is required" \
  "broken executable runtime: recovery warning requires repair"
assert_not_contains "$broken_executable_runtime_out" \
  "Runtime recovery source missing: current protection can still run" \
  "broken executable runtime: recovery warning does not claim protection can run"

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

INVALID_DISABLED_SKILLS_HOME="$(mktemp -d)"
invalid_disabled_json_rc=0
invalid_disabled_json="$(
  HOME="${INVALID_DISABLED_SKILLS_HOME}" \
    VIBEGUARD_DISABLED_SKILLS='plan-flow,,fixflow' \
    bash "${SETUP_SCRIPT}" --check --json 2>/dev/null
)" || invalid_disabled_json_rc=$?
assert_eq "${invalid_disabled_json_rc}" "2" \
  "invalid disabled-skills override: JSON check exits broken"
assert_json_path "${invalid_disabled_json}" \
  'any("Codex home installation check failed" in event["message"] for event in d["events"])' \
  "True" "invalid disabled-skills override: JSON exposes a FAIL event"

invalid_disabled_verify_rc=0
invalid_disabled_verify_out="$(
  HOME="${INVALID_DISABLED_SKILLS_HOME}" \
    VIBEGUARD_DISABLED_SKILLS='plan-flow,,fixflow' \
    bash "${SETUP_SCRIPT}" verify-install 2>&1
)" || invalid_disabled_verify_rc=$?
assert_eq "${invalid_disabled_verify_rc}" "2" \
  "invalid disabled-skills override: verify-install exits broken"
assert_contains "${invalid_disabled_verify_out}" \
  "[FAIL] Codex home installation check failed" \
  "invalid disabled-skills override: verify-install exposes the failure"

INVALID_QUARANTINE_STATE_HOME="$(mktemp -d)"
mkdir -p "${INVALID_QUARANTINE_STATE_HOME}/.vibeguard"
printf '%s\n' '{"version":1,"files":{},"disabled_skill_quarantines":{"/tmp/plan-flow":{"version":1,"quarantine":7,"transaction":"/tmp/.plan-flow.vibeguard-transaction.nonce.json","source_prefix":"skills/plan-flow","tracked_digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","install_state_generation":1,"nonce":"nonce"}}}' \
  > "${INVALID_QUARANTINE_STATE_HOME}/.vibeguard/install-state.json"
invalid_quarantine_json_rc=0
invalid_quarantine_json="$(
  HOME="${INVALID_QUARANTINE_STATE_HOME}" \
    VIBEGUARD_SETUP_RUNTIME="${CURRENT_SETUP_RUNTIME}" \
    bash "${SETUP_SCRIPT}" --check --json 2>/dev/null
)" || invalid_quarantine_json_rc=$?
assert_eq "${invalid_quarantine_json_rc}" "2" \
  "invalid quarantine state: JSON check exits broken"
assert_json_path "${invalid_quarantine_json}" \
  'any("Install state drift check failed" in event["message"] for event in d["events"])' \
  "True" "invalid quarantine state: JSON exposes a FAIL event"
