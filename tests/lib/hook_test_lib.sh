#!/usr/bin/env bash

TEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${VIBEGUARD_REPO_DIR:-$(cd "${TEST_LIB_DIR}/../.." && pwd)}"
cd "$REPO_DIR"

PASS=0
FAIL=0
TOTAL=0

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

assert_contains() {
  local output="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qF "$expected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if ! echo "$output" | grep -qF "$unexpected"; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (unexpectedly contains: $unexpected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_occurrences() {
  local output="$1" needle="$2" expected_count="$3" desc="$4"
  local actual_count
  TOTAL=$((TOTAL + 1))
  actual_count=$(python3 -c '
import sys

haystack = sys.argv[1]
needle = sys.argv[2]
print(haystack.count(needle))
' "$output" "$needle")
  if [[ "$actual_count" == "$expected_count" ]]; then
    green "$desc"
    PASS=$((PASS + 1))
  else
    red "$desc (expected $expected_count occurrences of: $needle, got $actual_count)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_zero() {
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

assert_exit_nonzero() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (unexpected success)"
    FAIL=$((FAIL + 1))
  else
    green "$desc"
    PASS=$((PASS + 1))
  fi
}

hook_test_init() {
  export VIBEGUARD_LOG_DIR="${VIBEGUARD_LOG_DIR:-$(mktemp -d)}"
  trap 'rm -rf "$VIBEGUARD_LOG_DIR"' EXIT
}

hook_test_install_runtime_stub() {
  local home_dir="$1"
  local runtime="${home_dir}/.vibeguard/installed/bin/vibeguard-runtime"
  mkdir -p "$(dirname "$runtime")"
  cat > "$runtime" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

command="${1:-}"
shift || true

case "$command" in
  test-path-filter)
    mode="${1:-}"
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      normalized="${path//\\//}"
      normalized="$(printf '%s' "$normalized" | tr '[:upper:]' '[:lower:]')"
      base="${normalized##*/}"
      is_test=0
      case "$normalized" in
        tests/*|test/*|__tests__/*|spec/*|fixtures/*|mocks/*|testdata/*|examples/*|benches/*|test_*|*/tests/*|*/test/*|*/__tests__/*|*/spec/*|*/fixtures/*|*/mocks/*|*/testdata/*|*/examples/*|*/benches/*|*/test_*) is_test=1 ;;
      esac
      case "$base" in
        tests.rs|test_helpers.rs|test_*|*_test.*|*.test.*|*.spec.*|*_test.rs) is_test=1 ;;
      esac
      if [[ "$mode" == "--test" && "$is_test" -eq 1 ]] || [[ "$mode" == "--prod" && "$is_test" -eq 0 ]]; then
        printf '%s\n' "$path"
      fi
    done
    ;;
  codex-event-name)
    input="$(cat)"
    if [[ "$input" =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
    ;;
  wrapper-env)
    cli="${1:-${VIBEGUARD_CLI:-unknown}}"
    log_dir="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
    project_hash="${VIBEGUARD_PROJECT_HASH:-${VIBEGUARD_TEST_PROJECT_HASH:-abcdef12}}"
    project_dir="${VIBEGUARD_PROJECT_LOG_DIR:-${log_dir}/projects/${project_hash}}"
    log_file="${VIBEGUARD_LOG_FILE:-${project_dir}/events.jsonl}"
    session_id="${VIBEGUARD_SESSION_ID:-stub-session}"
    mkdir -p "$project_dir"
    printf '%s' "$PWD" > "${project_dir}/.project-root"
    printf 'VIBEGUARD_CLI=%s\n' "$cli"
    printf 'VIBEGUARD_PROJECT_HASH=%s\n' "$project_hash"
    printf 'VIBEGUARD_PROJECT_LOG_DIR=%s\n' "$project_dir"
    printf 'VIBEGUARD_LOG_FILE=%s\n' "$log_file"
    printf 'VIBEGUARD_SESSION_ID=%s\n' "$session_id"
    ;;
  runtime-policy-supports)
    ;;
  runtime-policy-check)
    cwd=""
    hook_name=""
    while [[ $# -gt 0 ]]; do
      case "${1:-}" in
        --cwd)
          shift
          cwd="${1:-}"
          [[ $# -gt 0 ]] && shift
          ;;
        *)
          hook_name="$1"
          shift
          ;;
      esac
    done
    printf '{"decision":"run","enforcement":"block","hook":"%s","profile":"core","config_path":null,"cwd":"%s","reason":null}\n' "${hook_name:-unknown}" "${cwd}"
    ;;
  append-jsonl-mirror)
    primary_file="${1:?append-jsonl-mirror requires a primary file path}"
    mirror_file="${2:?append-jsonl-mirror requires a mirror file path}"
    line="$(cat)"
    mkdir -p "$(dirname "$primary_file")" "$(dirname "$mirror_file")"
    printf '%s\n' "$line" >> "$primary_file"
    if [[ "$primary_file" != "$mirror_file" ]]; then
      printf '%s\n' "$line" >> "$mirror_file"
    fi
    ;;
  append-jsonl)
    file="${1:?append-jsonl requires a file path}"
    line="$(cat)"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$line" >> "$file"
    ;;
  json-field)
    strict=0
    if [[ "${1:-}" == "--strict" ]]; then
      strict=1
      shift
    fi
    field="${1:-}"
    input="$(cat)"
    RUNTIME_INPUT="$input" python3 - "$field" "$strict" <<'PY'
import json
import os
import sys

field = sys.argv[1]
strict = sys.argv[2] == "1"
try:
    value = json.loads(os.environ.get("RUNTIME_INPUT", ""))
    for part in field.split("."):
        value = value[part]
except Exception:
    if strict:
        raise SystemExit(1)
    print("")
    raise SystemExit(0)
if value is None:
    if strict:
        raise SystemExit(1)
    print("")
elif isinstance(value, str):
    print(value)
else:
    print(json.dumps(value))
PY
    ;;
  pkg-rewrite)
    cat >/dev/null
    ;;
  pre-write-check)
    cat >/dev/null
    printf 'PASS\n'
    ;;
  hook)
    hook_name="${1:-}"
    input="$(cat || true)"
    case "$hook_name" in
      pre-bash|pre-bash-guard)
        event_hook="pre-bash-guard"
        event_tool="Bash"
        detail="$(RUNTIME_INPUT="$input" python3 - <<'PY'
import json
import os

try:
    print(json.loads(os.environ.get("RUNTIME_INPUT", "")).get("tool_input", {}).get("command", ""))
except Exception:
    print("")
PY
)"
        ;;
      stop|stop-guard)
        event_hook="stop-guard"
        event_tool="Stop"
        detail=""
        ;;
      *)
        event_hook="${hook_name:-unknown}"
        event_tool="unknown"
        detail=""
        ;;
    esac
    log_dir="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
    project_hash="${VIBEGUARD_PROJECT_HASH:-${VIBEGUARD_TEST_PROJECT_HASH:-abcdef12}}"
    project_dir="${VIBEGUARD_PROJECT_LOG_DIR:-${log_dir}/projects/${project_hash}}"
    log_file="${VIBEGUARD_LOG_FILE:-${project_dir}/events.jsonl}"
    global_log="${log_dir}/events.jsonl"
    mkdir -p "$(dirname "$log_file")" "$log_dir"
    RUNTIME_HOOK="$event_hook" \
    RUNTIME_TOOL="$event_tool" \
    RUNTIME_DETAIL="$detail" \
    RUNTIME_LOG_FILE="$log_file" \
    RUNTIME_GLOBAL_LOG="$global_log" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

cli = os.environ.get("VIBEGUARD_CLI", "unknown")
client = os.environ.get("VIBEGUARD_CLIENT")
if not client:
    client = cli if cli in {"claude", "codex"} else "unknown"
client_variant = os.environ.get("VIBEGUARD_CLIENT_VARIANT")
if not client_variant:
    client_variant = {
        "claude": "claude-code-hooks",
        "codex": "codex-cli-hooks",
    }.get(client, "unknown")

event = {
    "schema_version": 1,
    "ts": "2026-01-01T00:00:00Z",
    "session": os.environ.get("VIBEGUARD_SESSION_ID", "stub-session"),
    "hook": os.environ["RUNTIME_HOOK"],
    "tool": os.environ["RUNTIME_TOOL"],
    "decision": "pass",
    "status": "pass",
    "reason": "",
    "detail": os.environ.get("RUNTIME_DETAIL", ""),
    "duration_ms": 1,
    "cli": cli,
    "client": client,
    "client_variant": client_variant,
    "caller_evidence": os.environ.get("VIBEGUARD_CALLER_EVIDENCE", "stub"),
}
for env_name, key in [
    ("VIBEGUARD_WRAPPER", "wrapper"),
    ("VIBEGUARD_SOURCE_CONFIG", "source_config"),
    ("VIBEGUARD_HOOK_PROTOCOL_VERSION", "hook_protocol_version"),
]:
    value = os.environ.get(env_name)
    if value:
        event[key] = value
line = json.dumps(event)
for name in ["RUNTIME_LOG_FILE", "RUNTIME_GLOBAL_LOG"]:
    path = Path(os.environ[name])
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")
PY
    ;;
  *)
    cat >/dev/null || true
    ;;
esac
STUB
  chmod +x "$runtime"
}

hook_test_write_policy_runtime_probe_stub() {
  local runtime="$1"
  cat > "$runtime" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

command="${1:-}"
shift || true

log_probe() {
  [[ -z "${VG_STUB_LOG:-}" ]] || printf '%s\n' "$1" >>"${VG_STUB_LOG}"
}

case "$command" in
  runtime-policy-supports)
    log_probe "supports"
    ;;
  runtime-policy-check)
    if [[ "${VG_STUB_STALE_PROTOCOL:-0}" == "1" ]]; then
      if [[ "$#" -ne 1 || "${1:-}" == --* ]]; then
        printf 'Usage: vibeguard-runtime runtime-policy-check <hook-name>\n' >&2
        exit 2
      fi
      exit 0
    fi
    log_probe "check:runtime-policy-check $*"
    cwd=""
    hook_name=""
    while [[ $# -gt 0 ]]; do
      case "${1:-}" in
        --cwd)
          shift
          cwd="${1:-}"
          shift || true
          ;;
        *)
          hook_name="$1"
          shift
          ;;
      esac
    done
    printf '{"decision":"run","enforcement":"%s","hook":"%s","profile":"core","config_path":null,"cwd":"%s","reason":"compat text says enforcement=warn"}\n' "${VG_STUB_ENFORCEMENT:-block}" "${hook_name:-unknown}" "${cwd}"
    ;;
  json-field)
    log_probe "json-field:$*"
    exec "${REAL_RUNTIME:?}" json-field "$@"
    ;;
  runtime-policy-downgrade-output)
    log_probe "downgrade"
    exec "${REAL_RUNTIME:?}" runtime-policy-downgrade-output
    ;;
  runtime-policy-codex-error)
    log_probe "codex-error:$*"
    exec "${REAL_RUNTIME:?}" runtime-policy-codex-error "$@"
    ;;
  runtime-policy-diag)
    log_probe "diag:$*"
    exec "${REAL_RUNTIME:?}" runtime-policy-diag "$@"
    ;;
  *)
    exit 2
    ;;
esac
STUB
  chmod +x "$runtime"
}

hook_test_finish() {
  echo
  echo "=============================="
  printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
  echo "=============================="

  if [[ $FAIL -gt 0 ]]; then
    exit 1
  fi
}
