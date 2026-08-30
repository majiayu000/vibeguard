#!/usr/bin/env bash
# Validate the repo-local Codex App plugin package.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="${REPO_DIR}/plugins/vibeguard"
PLUGIN_SCRIPT="${PLUGIN_DIR}/scripts/vibeguard-plugin.sh"
PLUGIN_JSON="${PLUGIN_DIR}/.codex-plugin/plugin.json"
MARKETPLACE_JSON="${REPO_DIR}/.agents/plugins/marketplace.json"
SKILL_VALIDATOR="${REPO_DIR}/scripts/ci/validate-skill-format.py"
DASHBOARD_TEST_JSON_PYTHON_BIN="$(command -v python3)"
export DASHBOARD_TEST_JSON_PYTHON_BIN

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

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

make_dashboard_fixture() {
  local fixture="$1"
  mkdir -p \
    "${fixture}/hooks" \
    "${fixture}/skills" \
    "${fixture}/scripts/lib" \
    "${fixture}/vibeguard-runtime"
  touch "${fixture}/vibeguard-runtime/Cargo.toml"
  touch "${fixture}/events.jsonl"
  cp "${REPO_DIR}/scripts/lib/runtime.sh" "${fixture}/scripts/lib/runtime.sh"

  cat > "${fixture}/setup.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'HUMAN STATUS: installed'
SH
  cat > "${fixture}/scripts/stats.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'HUMAN STATS: sessions_with_later_build_pass: 901 <em>diagnostic</em>'
SH
  cat > "${fixture}/scripts/hook-health.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'HUMAN HEALTH: sessions_with_later_follow_up_pass: 902'
SH
  cat > "${fixture}/vibeguard-test-runtime" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "observe" && "${2:-}" == "value" ]]; then
  if [[ "${DASHBOARD_TEST_MODE:-}" == "unavailable" ]]; then
    printf '%s\n' 'unknown command: observe value' >&2
    exit 2
  fi
  if [[ "$*" == *"--days all"* ]]; then
    printf '%s\n' '{"command":"value","value":{"data_state":"observed"}}'
    exit 0
  fi
  case "${DASHBOARD_TEST_MODE:-}" in
    command-failure)
      printf '%s\n' '<script>alert("x")</script>' >&2
      exit 23
      ;;
    malformed)
      printf '%s\n' '{"value":<broken>}'
      exit 0
      ;;
  esac
  if [[ -n "${DASHBOARD_TEST_VALUE_JSON:-}" ]]; then
    printf '%s\n' "${DASHBOARD_TEST_VALUE_JSON}"
  else
    printf '%s\n' '{"command":"value","value":{"data_state":"empty"}}'
  fi
  exit 0
fi

if [[ "${1:-}" == "json-field" ]]; then
  shift
  strict=0
  if [[ "${1:-}" == "--strict" ]]; then
    strict=1
    shift
  fi
  field="${1:-}"
  payload="$(cat)"
  DASHBOARD_TEST_JSON_PAYLOAD="${payload}" \
    "${DASHBOARD_TEST_JSON_PYTHON_BIN}" - "${strict}" "${field}" <<'PY'
import json
import os
import sys

strict = sys.argv[1] == "1"
value = json.loads(os.environ["DASHBOARD_TEST_JSON_PAYLOAD"])
try:
    for part in sys.argv[2].split("."):
        value = value[int(part)] if isinstance(value, list) else value[part]
except (KeyError, IndexError, TypeError, ValueError):
    if strict:
        raise SystemExit(1)
    value = None
if value is None:
    if strict:
        raise SystemExit(1)
    print("")
elif isinstance(value, str):
    print(value)
else:
    print(json.dumps(value, separators=(",", ":")))
PY
  exit $?
fi

printf 'unexpected runtime command:' >&2
printf ' %q' "$@" >&2
printf '%s\n' '' >&2
exit 2
SH
  chmod +x \
    "${fixture}/setup.sh" \
    "${fixture}/scripts/stats.sh" \
    "${fixture}/scripts/hook-health.sh" \
    "${fixture}/vibeguard-test-runtime"
}

run_dashboard_fixture() {
  local mode="$1"
  local value_json="$2"
  local fixture="$3"
  local output_path="$4"
  shift 4

  DASHBOARD_TEST_MODE="${mode}" \
    DASHBOARD_TEST_VALUE_JSON="${value_json}" \
    VIBEGUARD_RUNTIME="${fixture}/vibeguard-test-runtime" \
    VIBEGUARD_REPO_DIR="${fixture}" \
    bash "${PLUGIN_SCRIPT}" dashboard \
      --no-open \
      --output "${output_path}" \
      --log-file "${fixture}/events.jsonl" \
      "$@" >/dev/null
}

dashboard_require_contains() {
  local expected="$1"
  local file="$2"
  grep -qF -- "${expected}" "${file}"
}

dashboard_require_absent() {
  local forbidden="$1"
  local file="$2"
  ! grep -qF -- "${forbidden}" "${file}"
}

dashboard_json_evidence_test() {
  local tmp_dir fixture output_path value_json
  tmp_dir="$(mktemp -d)"
  fixture="${tmp_dir}/repo"
  output_path="${tmp_dir}/dashboard.html"
  value_json='{"command":"value","value":{"data_state":"observed","verified":{"sessions_with_later_build_pass":17},"observed":{"attention_events":23,"sessions_with_attention":9,"sessions_with_later_follow_up_pass":13,"sessions_without_later_follow_up_pass":4,"sessions_with_repeated_attention":6,"uncorrelatable_attention_events":3,"suppression_events":5,"hook_duration_ms":{"count":8,"total_ms":1440,"avg_ms":180,"p95_ms":400}},"estimated":{"available":false,"reason":"No causal data."},"limitations":["Association only.","Literal {{name}} token."]}}'
  make_dashboard_fixture "${fixture}"
  run_dashboard_fixture observed "${value_json}" "${fixture}" "${output_path}"
  dashboard_require_contains 'data-evidence="verified-build-pass">17<' "${output_path}" || return 1
  dashboard_require_contains 'data-evidence="observed-follow-up">13<' "${output_path}" || return 1
  dashboard_require_contains 'data-evidence="unresolved-attention">4<' "${output_path}" || return 1
  dashboard_require_contains 'data-evidence="hook-overhead">180 ms<' "${output_path}" || return 1
  dashboard_require_contains 'data-friction="repeated-attention">6<' "${output_path}" || return 1
  dashboard_require_contains 'data-friction="suppressions">5<' "${output_path}" || return 1
  dashboard_require_contains 'data-friction="uncorrelatable">3<' "${output_path}" || return 1
  dashboard_require_contains '&lt;em&gt;diagnostic&lt;/em&gt;' "${output_path}" || return 1
  dashboard_require_contains 'Literal {{name}} token.' "${output_path}" || return 1
  dashboard_require_absent 'data-evidence="verified-build-pass">901<' "${output_path}" || return 1
  dashboard_require_absent 'data-evidence="observed-follow-up">902<' "${output_path}" || return 1
  rm -rf "${tmp_dir}"
}

dashboard_verified_plus_partial_story_test() {
  local tmp_dir fixture output_path value_json
  tmp_dir="$(mktemp -d)"
  fixture="${tmp_dir}/repo"
  output_path="${tmp_dir}/dashboard.html"
  value_json='{"command":"value","value":{"data_state":"observed","verified":{"sessions_with_later_build_pass":1},"observed":{"attention_events":2,"sessions_with_attention":1,"sessions_with_later_follow_up_pass":1,"sessions_without_later_follow_up_pass":0,"sessions_with_repeated_attention":0,"uncorrelatable_attention_events":1,"suppression_events":0,"hook_duration_ms":{"count":1,"total_ms":24,"avg_ms":24,"p95_ms":24}},"estimated":{"available":false,"reason":"No causal data."},"limitations":["One event could not be correlated."]}}'
  make_dashboard_fixture "${fixture}"
  run_dashboard_fixture observed "${value_json}" "${fixture}" "${output_path}"
  dashboard_require_contains 'A later build pass is recorded after VibeGuard stepped in.' "${output_path}" || return 1
  dashboard_require_contains 'Partial / unresolved local evidence' "${output_path}" || return 1
  dashboard_require_contains 'Evidence is partial: 1 guardrail signal could not be correlated by session and timestamp.' "${output_path}" || return 1
  dashboard_require_contains 'data-friction="uncorrelatable">1<' "${output_path}" || return 1
  rm -rf "${tmp_dir}"
}

dashboard_empty_and_unresolved_states_test() {
  local tmp_dir fixture output_path missing_json empty_json unresolved_json
  tmp_dir="$(mktemp -d)"
  fixture="${tmp_dir}/repo"
  output_path="${tmp_dir}/dashboard.html"
  missing_json='{"command":"value","value":{"data_state":"missing","verified":{"sessions_with_later_build_pass":0},"observed":{"attention_events":0,"sessions_with_attention":0,"sessions_with_later_follow_up_pass":0,"sessions_without_later_follow_up_pass":0,"sessions_with_repeated_attention":0,"uncorrelatable_attention_events":0,"suppression_events":0,"hook_duration_ms":{"count":0,"total_ms":0,"avg_ms":0,"p95_ms":null}},"estimated":{"available":false,"reason":"No causal data."},"limitations":["Event log not found."]}}'
  empty_json='{"command":"value","value":{"data_state":"empty","verified":{"sessions_with_later_build_pass":0},"observed":{"attention_events":0,"sessions_with_attention":0,"sessions_with_later_follow_up_pass":0,"sessions_without_later_follow_up_pass":0,"sessions_with_repeated_attention":0,"uncorrelatable_attention_events":0,"suppression_events":0,"hook_duration_ms":{"count":0,"total_ms":0,"avg_ms":0,"p95_ms":null}},"estimated":{"available":false,"reason":"No causal data."},"limitations":[]}}'
  unresolved_json='{"command":"value","value":{"data_state":"observed","verified":{"sessions_with_later_build_pass":0},"observed":{"attention_events":7,"sessions_with_attention":5,"sessions_with_later_follow_up_pass":2,"sessions_without_later_follow_up_pass":3,"sessions_with_repeated_attention":3,"uncorrelatable_attention_events":4,"suppression_events":1,"hook_duration_ms":{"count":2,"total_ms":90,"avg_ms":45,"p95_ms":60}},"estimated":{"available":false,"reason":"No causal data."},"limitations":["Partial timestamps."]}}'
  make_dashboard_fixture "${fixture}"

  run_dashboard_fixture missing "${missing_json}" "${fixture}" "${output_path}"
  dashboard_require_contains 'data-state="missing"' "${output_path}" || return 1
  dashboard_require_contains 'The selected local event source is missing.' "${output_path}" || return 1
  dashboard_require_contains 'Check the selected log path and VibeGuard setup' "${output_path}" || return 1
  dashboard_require_absent 'Trigger one protected action in the project' "${output_path}" || return 1

  run_dashboard_fixture empty "${empty_json}" "${fixture}" "${output_path}"
  dashboard_require_contains 'data-state="empty"' "${output_path}" || return 1
  dashboard_require_contains 'No local event data in the selected window.' "${output_path}" || return 1
  dashboard_require_absent 'data-evidence="verified-build-pass">0<' "${output_path}" || return 1

  DASHBOARD_TEST_MODE=observed \
    DASHBOARD_TEST_VALUE_JSON="${empty_json}" \
    VIBEGUARD_RUNTIME="${fixture}/vibeguard-test-runtime" \
    VIBEGUARD_REPO_DIR="${fixture}" \
    bash "${PLUGIN_SCRIPT}" dashboard \
      --no-open \
      --output "${output_path}" \
      --log-file "${fixture}/missing-events.jsonl" >/dev/null
  dashboard_require_contains 'The selected local event source is missing.' "${output_path}" || return 1
  dashboard_require_contains 'Check the selected log path and VibeGuard setup' "${output_path}" || return 1
  dashboard_require_absent 'Update or build the VibeGuard runtime' "${output_path}" || return 1

  run_dashboard_fixture unresolved "${unresolved_json}" "${fixture}" "${output_path}"
  dashboard_require_contains 'Partial / unresolved local evidence' "${output_path}" || return 1
  dashboard_require_contains 'Evidence is partial: 4 guardrail signals could not be correlated by session and timestamp.' "${output_path}" || return 1
  dashboard_require_contains 'data-friction="repeated-attention">3<' "${output_path}" || return 1
  dashboard_require_contains 'data-friction="uncorrelatable">4<' "${output_path}" || return 1
  rm -rf "${tmp_dir}"
}

dashboard_failure_and_unavailable_states_test() {
  local tmp_dir fixture output_path
  tmp_dir="$(mktemp -d)"
  fixture="${tmp_dir}/repo"
  output_path="${tmp_dir}/dashboard.html"
  make_dashboard_fixture "${fixture}"

  run_dashboard_fixture command-failure '' "${fixture}" "${output_path}"
  dashboard_require_contains 'Evidence command failed; no headline evidence was rendered.' "${output_path}" || return 1
  dashboard_require_contains '&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;' "${output_path}" || return 1
  dashboard_require_absent '<script>alert("x")</script>' "${output_path}" || return 1

  run_dashboard_fixture malformed '' "${fixture}" "${output_path}"
  dashboard_require_contains 'Evidence output could not be parsed; no headline evidence was rendered.' "${output_path}" || return 1
  dashboard_require_contains '&lt;broken&gt;' "${output_path}" || return 1

  run_dashboard_fixture unavailable '' "${fixture}" "${output_path}" --scope project --project "${fixture}"
  dashboard_require_contains 'First-win evidence is unavailable' "${output_path}" || return 1
  dashboard_require_contains 'Update or build the VibeGuard runtime' "${output_path}" || return 1
  dashboard_require_absent 'data-evidence="verified-build-pass">0<' "${output_path}" || return 1
  dashboard_require_contains '--log-file' "${output_path}" || return 1
  dashboard_require_contains '--scope project' "${output_path}" || return 1
  dashboard_require_contains '--project' "${output_path}" || return 1
  rm -rf "${tmp_dir}"
}

dashboard_python_free_generation_test() {
  local tmp_dir fixture output_path poison_bin value_json
  tmp_dir="$(mktemp -d)"
  fixture="${tmp_dir}/repo"
  output_path="${tmp_dir}/dashboard.html"
  poison_bin="${tmp_dir}/bin"
  value_json='{"command":"value","value":{"data_state":"empty"}}'
  make_dashboard_fixture "${fixture}"
  mkdir -p "${poison_bin}"
  cat > "${poison_bin}/python3" <<'SH'
#!/usr/bin/env bash
exit 97
SH
  chmod +x "${poison_bin}/python3"

  PATH="${poison_bin}:${PATH}" run_dashboard_fixture empty "${value_json}" "${fixture}" "${output_path}"
  dashboard_require_contains '<!doctype html>' "${output_path}" || return 1
  rm -rf "${tmp_dir}"
}

dashboard_static_contract_test() {
  local tmp_dir fixture output_path value_json
  tmp_dir="$(mktemp -d)"
  fixture="${tmp_dir}/repo with spaces"
  output_path="${tmp_dir}/dashboard.html"
  value_json='{"command":"value","value":{"data_state":"observed","verified":{"sessions_with_later_build_pass":1},"observed":{"attention_events":1,"sessions_with_attention":1,"sessions_with_later_follow_up_pass":1,"sessions_without_later_follow_up_pass":0,"sessions_with_repeated_attention":0,"uncorrelatable_attention_events":0,"suppression_events":0,"hook_duration_ms":{"count":1,"total_ms":24,"avg_ms":24,"p95_ms":24}},"estimated":{"available":false,"reason":"No causal data."},"limitations":[]}}'
  make_dashboard_fixture "${fixture}"
  run_dashboard_fixture observed "${value_json}" "${fixture}" "${output_path}"
  dashboard_require_contains '<main class="shell" aria-labelledby="dashboard-title"' "${output_path}" || return 1
  dashboard_require_contains '<h1 id="dashboard-title">See what happened after VibeGuard stepped in.</h1>' "${output_path}" || return 1
  dashboard_require_contains '<div class="metric-label">Later build pass after intervention</div>' "${output_path}" || return 1
  dashboard_require_contains '<div class="metric-label">Sessions without later follow-up</div>' "${output_path}" || return 1
  dashboard_require_absent '>Guardrail signals without follow-up<' "${output_path}" || return 1
  dashboard_require_contains 'repo\ with\ spaces/setup.sh --codex-status' "${output_path}" || return 1
  dashboard_require_contains '<span>window</span><strong>last 7 days</strong>' "${output_path}" || return 1
  dashboard_require_contains '<details>' "${output_path}" || return 1
  dashboard_require_contains 'Local-only evidence' "${output_path}" || return 1
  dashboard_require_contains 'The built-in 5-positive/5-negative benchmark is a small reproducible corpus, not evidence of impact on your project.' "${output_path}" || return 1
  dashboard_require_contains 'prefers-reduced-motion' "${output_path}" || return 1
  dashboard_require_contains '@media (max-width: 760px)' "${output_path}" || return 1
  ! grep -q '<script' "${output_path}" || return 1
  ! grep -Eq 'https?://|//[A-Za-z]' "${output_path}" || return 1
  python3 - "${output_path}" <<'PY' || return 1
import stat
import sys
from pathlib import Path

mode = stat.S_IMODE(Path(sys.argv[1]).stat().st_mode)
raise SystemExit(0 if mode == 0o600 else 1)
PY
  rm -rf "${tmp_dir}"
}

dashboard_all_history_and_help_test() {
  local tmp_dir fixture output_path help_out
  tmp_dir="$(mktemp -d)"
  fixture="${tmp_dir}/repo"
  output_path="${tmp_dir}/dashboard.html"
  make_dashboard_fixture "${fixture}"
  DASHBOARD_TEST_MODE=observed \
    VIBEGUARD_RUNTIME="${fixture}/vibeguard-test-runtime" \
    VIBEGUARD_REPO_DIR="${fixture}" \
    bash "${PLUGIN_SCRIPT}" dashboard \
      --no-open \
      --days all \
      --output "${output_path}" \
      --log-file "${fixture}/events.jsonl" >/dev/null
  dashboard_require_contains '<span>window</span><strong>all available history</strong>' "${output_path}" || return 1
  dashboard_require_absent 'last all days' "${output_path}" || return 1

  help_out="$(bash "${PLUGIN_SCRIPT}" dashboard --help)"
  grep -qF 'Select value evidence, stats, and health scope' <<<"${help_out}" || return 1
  grep -qF 'Select project for value evidence, stats, and health' <<<"${help_out}" || return 1
  grep -qF 'Read value evidence, stats, and health from PATH' <<<"${help_out}" || return 1
  rm -rf "${tmp_dir}"
}

landing_page_evidence_journey_test() {
  local site_file="${REPO_DIR}/site/index.html"
  [[ "$(grep -c 'class="journey-step"' "${site_file}")" -eq 4 ]] || return 1
  ! grep -q 'class="journey-card"' "${site_file}" || return 1
  grep -qF '<h3>Problem surfaces</h3>' "${site_file}" || return 1
  grep -qF '<h3>Intervention</h3>' "${site_file}" || return 1
  grep -qF '<h3>Correction / follow-up</h3>' "${site_file}" || return 1
  grep -qF '<h3>Verification</h3>' "${site_file}" || return 1
  grep -qF 'What the local evidence can tell you' "${site_file}" || return 1
  grep -qF '<h3>Verified sequence</h3>' "${site_file}" || return 1
  grep -qF '<h3>Observed signals and friction</h3>' "${site_file}" || return 1
  grep -qF '<h3>Unavailable outcome claims</h3>' "${site_file}" || return 1
  grep -qF 'The built-in 5-positive/5-negative benchmark is a small reproducible corpus, not evidence of impact on your project.' "${site_file}" || return 1
  grep -qF 'git clone https://github.com/majiayu000/vibeguard.git ~/vibeguard && bash ~/vibeguard/setup.sh --yes' "${site_file}" || return 1
  ! grep -qF '<h3>Attention lands</h3>' "${site_file}" || return 1
}

assert_cmd "dashboard headline cards use observe value JSON, not human output" dashboard_json_evidence_test
assert_cmd "verified story remains primary when other evidence is partial" dashboard_verified_plus_partial_story_test
assert_cmd "dashboard makes empty and unresolved evidence explicit" dashboard_empty_and_unresolved_states_test
assert_cmd "dashboard renders command, parse, and runtime capability failures visibly" dashboard_failure_and_unavailable_states_test
assert_cmd "dashboard generation does not require Python" dashboard_python_free_generation_test
assert_cmd "dashboard HTML is semantic, responsive, local-only, and standalone" dashboard_static_contract_test
assert_cmd "dashboard renders all-history period and documents value-evidence selectors" dashboard_all_history_and_help_test
assert_cmd "landing page has one journey and a separate evidence-boundary explanation" landing_page_evidence_journey_test

header "codex plugin files"
assert_cmd "plugin manifest exists" test -f "${PLUGIN_JSON}"
assert_cmd "marketplace manifest exists" test -f "${MARKETPLACE_JSON}"
assert_cmd "plugin bridge script has valid syntax" bash -n "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh"
assert_cmd "plugin bridge resolves repo checkout" \
  bash "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh" repo-dir
assert_cmd "plugin bridge rejects invalid pinned repo checkout" bash -c '
  tmp_dir="$(mktemp -d)"
  trap "rm -rf \"${tmp_dir}\"" EXIT
  VIBEGUARD_REPO_DIR="${tmp_dir}/missing" bash "$1" repo-dir 2>"${tmp_dir}/stderr" && exit 1
  grep -q "VIBEGUARD_REPO_DIR is not a VibeGuard repository checkout" "${tmp_dir}/stderr"
' _ "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh"
assert_cmd "plugin dashboard generator writes local HTML" bash -c '
  tmp_dir="$(mktemp -d)"
  trap "rm -rf \"${tmp_dir}\"" EXIT
  VIBEGUARD_REPO_DIR="$2" bash "$1" dashboard --no-open --output "${tmp_dir}/dashboard.html" --log-file /dev/null >/dev/null
  test -f "${tmp_dir}/dashboard.html"
  grep -q "VibeGuard Observability" "${tmp_dir}/dashboard.html"
  ! LC_ALL=C grep -q "$(printf "\033")" "${tmp_dir}/dashboard.html"
' _ "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh" "${REPO_DIR}"
assert_cmd "plugin dashboard rejects global scope with project filter" bash -c '
  tmp_dir="$(mktemp -d)"
  trap "rm -rf \"${tmp_dir}\"" EXIT
  VIBEGUARD_REPO_DIR="$2" bash "$1" dashboard --no-open --output "${tmp_dir}/dashboard.html" --project "${tmp_dir}" --scope global 2>"${tmp_dir}/stderr" && exit 1
  grep -q -- "--project cannot be used with --scope global" "${tmp_dir}/stderr"
  test ! -f "${tmp_dir}/dashboard.html"
' _ "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh" "${REPO_DIR}"
assert_cmd "plugin dashboard generator renders command failures" bash -c '
  tmp_dir="$(mktemp -d)"
  trap "rm -rf \"${tmp_dir}\"" EXIT
  fake_repo="${tmp_dir}/fake-repo"
  mkdir -p "${fake_repo}/hooks" "${fake_repo}/skills" "${fake_repo}/scripts" "${fake_repo}/vibeguard-runtime"
  touch "${fake_repo}/vibeguard-runtime/Cargo.toml"
  cat > "${fake_repo}/setup.sh" <<SH
#!/usr/bin/env bash
printf "%s\n" "fake setup unavailable" >&2
exit 127
SH
  cat > "${fake_repo}/scripts/stats.sh" <<SH
#!/usr/bin/env bash
printf "%s\n" "fake stats unavailable" >&2
exit 127
SH
  cat > "${fake_repo}/scripts/hook-health.sh" <<SH
#!/usr/bin/env bash
printf "%s\n" "fake health unavailable" >&2
exit 127
SH
  chmod +x "${fake_repo}/setup.sh" "${fake_repo}/scripts/stats.sh" "${fake_repo}/scripts/hook-health.sh"
  VIBEGUARD_REPO_DIR="${fake_repo}" bash "$1" dashboard --no-open --output "${tmp_dir}/dashboard.html" --log-file /dev/null >/dev/null
  grep -q "COMMAND FAILED" "${tmp_dir}/dashboard.html"
' _ "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh"
assert_cmd "plugin health bridge runs against fake runtime" bash -c '
  tmp_dir="$(mktemp -d)"
  trap "rm -rf \"${tmp_dir}\"" EXIT
  runtime="${tmp_dir}/vibeguard-runtime"
  cat > "${runtime}" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "observe" && "\${2:-}" == "health" ]]; then
  printf "%s\n" "fake health"
  exit 0
fi
printf "unexpected runtime command:" >&2
printf " %q" "\$@" >&2
printf "\n" >&2
exit 2
SH
  chmod +x "${runtime}"
  VIBEGUARD_RUNTIME="${runtime}" bash "$1" health --log-file /dev/null 24
' _ "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh"
assert_cmd "plugin stats bridge runs against fake runtime" bash -c '
  tmp_dir="$(mktemp -d)"
  trap "rm -rf \"${tmp_dir}\"" EXIT
  runtime="${tmp_dir}/vibeguard-runtime"
  cat > "${runtime}" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "observe" && "\${2:-}" == "summary" ]]; then
  printf "%s\n" "fake stats"
  exit 0
fi
printf "unexpected runtime command:" >&2
printf " %q" "\$@" >&2
printf "\n" >&2
exit 2
SH
  chmod +x "${runtime}"
  VIBEGUARD_RUNTIME="${runtime}" bash "$1" stats --log-file /dev/null all
' _ "${PLUGIN_DIR}/scripts/vibeguard-plugin.sh"

header "plugin manifest contract"
assert_cmd "plugin manifest validates local contract" python3 - "${PLUGIN_JSON}" "${PLUGIN_DIR}" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
plugin_dir = Path(sys.argv[2])
payload = json.loads(manifest_path.read_text(encoding="utf-8"))

def fail(message: str) -> None:
    raise SystemExit(message)

raw = manifest_path.read_text(encoding="utf-8")
if "[TODO:" in raw:
    fail("plugin manifest must not contain TODO placeholders")

if payload.get("name") != "vibeguard":
    fail("plugin name must be vibeguard")
if not re.fullmatch(r"\d+\.\d+\.\d+", payload.get("version", "")):
    fail("plugin version must be strict semver")
if payload.get("skills") != "./skills/":
    fail("plugin skills path must be ./skills/")
if not (plugin_dir / "skills").is_dir():
    fail("plugin skills directory is missing")
if "hooks" in payload:
    fail("plugin manifest must not declare hooks; setup installs hooks explicitly")
for optional_path_field in ("mcpServers", "apps"):
    if optional_path_field in payload:
        rel = payload[optional_path_field]
        if not rel.startswith("./"):
            fail(f"{optional_path_field} must be relative")
        if not (plugin_dir / rel.removeprefix("./")).exists():
            fail(f"{optional_path_field} points at a missing file")

interface = payload.get("interface")
if not isinstance(interface, dict):
    fail("interface must be an object")
for field in ("displayName", "shortDescription", "longDescription", "developerName", "category"):
    if not interface.get(field):
        fail(f"interface.{field} is required")
for asset_field in ("composerIcon", "logo"):
    if asset_field in interface:
        rel = interface[asset_field]
        if not rel.startswith("./"):
            fail(f"interface.{asset_field} must be relative")
        if not (plugin_dir / rel.removeprefix("./")).is_file():
            fail(f"interface.{asset_field} points at a missing file")
prompts = interface.get("defaultPrompt")
if not isinstance(prompts, list) or len(prompts) > 3:
    fail("interface.defaultPrompt must be a list of at most three prompts")
for prompt in prompts:
    if len(prompt) > 128:
        fail("interface.defaultPrompt entries must be 128 chars or shorter")
print("OK")
PY

header "marketplace contract"
assert_cmd "marketplace manifest validates local contract" python3 - "${MARKETPLACE_JSON}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if "[TODO:" in Path(sys.argv[1]).read_text(encoding="utf-8"):
    raise SystemExit("marketplace manifest must not contain TODO placeholders")
if payload.get("name") != "vibeguard-local":
    raise SystemExit("marketplace name must be vibeguard-local")
plugins = payload.get("plugins")
if not isinstance(plugins, list):
    raise SystemExit("plugins must be a list")
matches = [entry for entry in plugins if isinstance(entry, dict) and entry.get("name") == "vibeguard"]
if len(matches) != 1:
    raise SystemExit("marketplace must contain exactly one vibeguard entry")
entry = matches[0]
if entry.get("source") != {"source": "local", "path": "./plugins/vibeguard"}:
    raise SystemExit("vibeguard marketplace source path drifted")
if entry.get("policy", {}).get("installation") != "AVAILABLE":
    raise SystemExit("vibeguard install policy must be AVAILABLE")
if entry.get("policy", {}).get("authentication") != "ON_INSTALL":
    raise SystemExit("vibeguard auth policy must be ON_INSTALL")
if entry.get("category") != "Developer Tools":
    raise SystemExit("vibeguard marketplace category must be Developer Tools")
print("OK")
PY

header "plugin skills"
while IFS= read -r skill_file; do
  assert_cmd "skill format: ${skill_file#${REPO_DIR}/}" \
    python3 "${SKILL_VALIDATOR}" "${skill_file}"
done < <(find "${PLUGIN_DIR}/skills" -name SKILL.md -type f | sort)

echo ""
echo "==========================="
if [[ "${FAIL}" -eq 0 ]]; then
  echo "All checks passed."
else
  echo "FAILED checks (${FAIL})"
fi
echo "==========================="
echo ""

exit $((FAIL > 0 ? 1 : 0))
