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
  *)
    cat >/dev/null || true
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
