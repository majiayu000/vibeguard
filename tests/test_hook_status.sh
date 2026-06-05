#!/usr/bin/env bash
# Regression tests for the hook-status runtime command and schema.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="${REPO_DIR}/vibeguard-runtime/target/debug/vibeguard-runtime"
TMP_DIR="$(mktemp -d)"
export VIBEGUARD_CODEX_DIAG_FILE="${TMP_DIR}/missing-codex-wrapper.jsonl"

cleanup() {
  rm -rf "${TMP_DIR}"
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

header "build"
assert_cmd "vibeguard-runtime builds" cargo build --manifest-path "${REPO_DIR}/vibeguard-runtime/Cargo.toml" --quiet

HOOK_LOG="${TMP_DIR}/events.jsonl"
DIAG_LOG="${TMP_DIR}/codex-wrapper.jsonl"
NO_DIAG_LOG="${TMP_DIR}/no-diag.jsonl"
RUNNING_LOG="${TMP_DIR}/running.jsonl"
JSON_OUT="${TMP_DIR}/hook-status.json"

cat > "${HOOK_LOG}" <<'JSONL'
{"ts":"2026-05-31T00:00:01Z","session":"s1","hook":"pre-bash-guard","tool":"Bash","decision":"pass","reason":"","detail":"git status","duration_ms":18}
{"ts":"2026-05-31T00:00:02Z","session":"s1","hook":"post-build-check","tool":"PostToolUse","decision":"pass","reason":"skip: missing file_path","detail":"","duration_ms":28}
{"ts":"2026-05-31T00:00:03Z","session":"s1","hook":"post-edit-guard","tool":"Edit","decision":"warn","reason":"unwrap detected","detail":"src/main.rs","duration_ms":44}
{"ts":"2026-05-31T00:00:04Z","session":"s1","hook":"pre-write-guard","tool":"Write","decision":"block","reason":"new source file without search","detail":"src/new.rs","duration_ms":20}
{"ts":"2026-05-31T00:00:05Z","session":"s1","hook":"post-write-guard","tool":"Write","decision":"pass","reason":"","detail":"src/lib.rs","duration_ms":2500}
{"ts":"2026-05-31T00:00:06Z","session":"s1","hook":"post-build-check","tool":"PostToolUse","decision":"warn","reason":"post-build-check timeout after 30s while running: npx tsc --noEmit","detail":"Edit src/foo.ts","duration_ms":30000}
JSONL

cat > "${DIAG_LOG}" <<'JSONL'
{"ts":"2026-05-31T00:00:00Z","cli":"codex","hook":"post-build-check","event":"PostToolUse","matcher":"Bash","status":"running","detail":"Edit src/foo.ts","timeout_ms":30000}
{"ts":"2026-05-31T00:00:07Z","cli":"codex","hook":"vibeguard-post-build-check.sh","event":"PostToolUse","reason":"posttool-adapter-failed","detail":"invalid json"}
JSONL

cat > "${RUNNING_LOG}" <<'JSONL'
{"ts":"2026-05-31T00:00:01Z","session":"s1","hook":"vibeguard-post-build-check.sh","event":"PostToolUse","matcher":"Bash","status":"running","reason":"npx tsc --noEmit","detail":"Edit src/foo.ts","elapsed_ms":12000,"timeout_ms":30000}
{"ts":"2026-05-31T00:00:02Z","session":"s1","hook":"orca-bridge","event":"PostToolUse","matcher":"Bash","decision":"pass","reason":"skip: ORCA env absent","detail":"Edit src/foo.ts","duration_ms":3}
JSONL

header "human output"
focused_out="$("${RUNTIME}" hook-status --mode focused --log-file "${HOOK_LOG}" --diag-file "${DIAG_LOG}" --slow-ms 2000 2>&1)"
assert_contains "$focused_out" "PostToolUse hook timed out - post-build-check - 30s" "focused: timeout headline is visible"
assert_contains "$focused_out" "Last action: Edit src/foo.ts" "focused: timeout includes last action"
assert_contains "$focused_out" "Log: ${HOOK_LOG}" "focused: timeout includes log path"
assert_contains "$focused_out" "[skip] post-build-check PostToolUse(<none>) skipped - missing file_path - 28ms" "focused: skip result is visible"
assert_contains "$focused_out" "[error] vibeguard-post-build-check.sh PostToolUse(<none>) adapter_error - posttool-adapter-failed" "focused: adapter error is visible"
assert_not_contains "$focused_out" "[running] post-build-check" "focused: completed hooks drop stale running status"
assert_not_contains "$focused_out" "additionalContext" "focused: pass/skip summaries do not inject model context"

running_out="$("${RUNTIME}" hook-status --mode minimal --log-file "${RUNNING_LOG}" --diag-file "${NO_DIAG_LOG}" --slow-ms 2000 2>&1)"
assert_contains "$running_out" "PostToolUse checks  1/2 running - 12s / 30s" "minimal: running state shows elapsed and timeout"

cat > "${TMP_DIR}/mixed-events.jsonl" <<'JSONL'
{"ts":"2026-05-31T00:00:01Z","session":"s1","hook":"pre-bash-guard","tool":"Bash","decision":"pass","reason":"","detail":"git status","duration_ms":18}
{"ts":"2026-05-31T00:00:02Z","session":"s1","hook":"post-build-check","tool":"PostToolUse","decision":"pass","reason":"skip: missing file_path","detail":"","duration_ms":28}
JSONL
mixed_out="$("${RUNTIME}" hook-status --mode minimal --log-file "${TMP_DIR}/mixed-events.jsonl" --diag-file "${NO_DIAG_LOG}" --slow-ms 2000 2>&1)"
assert_contains "$mixed_out" "PostToolUse checks  1/1 complete - 28ms" "minimal: summary counts only the displayed event"

cat > "${TMP_DIR}/same-second-events.jsonl" <<'JSONL'
{"ts":"2026-05-31T00:00:00Z","session":"s1","hook":"post-build-check","tool":"PostToolUse","decision":"warn","reason":"build warning","detail":"Edit src/foo.ts","duration_ms":44}
JSONL
cat > "${TMP_DIR}/same-second-diag.jsonl" <<'JSONL'
{"ts":"2026-05-31T00:00:00Z","cli":"codex","hook":"post-build-check","event":"PostToolUse","matcher":"Bash","status":"running","detail":"Edit src/foo.ts","timeout_ms":30000}
JSONL
same_second_out="$("${RUNTIME}" hook-status --mode focused --log-file "${TMP_DIR}/same-second-events.jsonl" --diag-file "${TMP_DIR}/same-second-diag.jsonl" --slow-ms 2000 2>&1)"
assert_not_contains "$same_second_out" "[running] post-build-check" "focused: same-second completion drops stale running status"

header "log scope resolution"
SCOPE_LOG_ROOT="${TMP_DIR}/scope-logs"
SCOPE_PROJECT_DIR="${SCOPE_LOG_ROOT}/projects/abcdef12"
mkdir -p "${SCOPE_PROJECT_DIR}"
printf '%s' "${REPO_DIR}" > "${SCOPE_PROJECT_DIR}/.project-root"
cat > "${SCOPE_PROJECT_DIR}/events.jsonl" <<'JSONL'
{"ts":"2026-05-31T00:00:01Z","session":"scope-project","hook":"pre-bash-guard","tool":"Bash","decision":"pass","reason":"","detail":"project-only","duration_ms":18}
JSONL
cat > "${SCOPE_LOG_ROOT}/events.jsonl" <<'JSONL'
{"ts":"2026-05-31T00:00:01Z","session":"scope-global","hook":"pre-bash-guard","tool":"Bash","decision":"pass","reason":"","detail":"global-only","duration_ms":18}
JSONL
project_default_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${SCOPE_LOG_ROOT}" "${RUNTIME}" hook-status --mode full --diag-file "${NO_DIAG_LOG}" --limit 5 2>&1)"
assert_contains "$project_default_out" "project-only" "scope: git repo default reads project log"
assert_not_contains "$project_default_out" "global-only" "scope: project default does not fall back to global log"

project_hash_out="$(VIBEGUARD_LOG_DIR="${SCOPE_LOG_ROOT}" "${RUNTIME}" hook-status --mode full --project abcdef12 --diag-file "${NO_DIAG_LOG}" --limit 5 2>&1)"
assert_contains "$project_hash_out" "project-only" "scope: --project accepts project hash"

global_scope_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${SCOPE_LOG_ROOT}" "${RUNTIME}" hook-status --mode full --scope global --diag-file "${NO_DIAG_LOG}" --limit 5 2>&1)"
assert_contains "$global_scope_out" "global-only" "scope: --scope global reads global log"
assert_not_contains "$global_scope_out" "project-only" "scope: global does not read project log"

explicit_log_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${SCOPE_LOG_ROOT}" "${RUNTIME}" hook-status --mode full --scope project --log-file "${SCOPE_LOG_ROOT}/events.jsonl" --diag-file "${NO_DIAG_LOG}" --limit 5 2>&1)"
assert_contains "$explicit_log_out" "global-only" "scope: --log-file wins over project scope"

MISSING_LOG_ROOT="${TMP_DIR}/scope-missing"
mkdir -p "${MISSING_LOG_ROOT}"
cat > "${MISSING_LOG_ROOT}/events.jsonl" <<'JSONL'
{"ts":"2026-05-31T00:00:01Z","session":"scope-global","hook":"pre-bash-guard","tool":"Bash","decision":"pass","reason":"","detail":"global-only","duration_ms":18}
JSONL
missing_project_out="$(cd "${REPO_DIR}" && VIBEGUARD_LOG_DIR="${MISSING_LOG_ROOT}" "${RUNTIME}" hook-status --mode full --diag-file "${NO_DIAG_LOG}" --limit 5 2>&1)"
assert_contains "$missing_project_out" "No hook status events found in" "scope: missing project log reports clear no-data path"
assert_contains "$missing_project_out" "/projects/" "scope: missing project log points at project path"
assert_not_contains "$missing_project_out" "global-only" "scope: missing project log does not fall back to global data"

header "json output"
"${RUNTIME}" hook-status --json --mode full --log-file "${HOOK_LOG}" --diag-file "${DIAG_LOG}" --slow-ms 2000 > "${JSON_OUT}"
assert_cmd "json: output parses" python3 -c "import json; json.load(open('${JSON_OUT}'))"
assert_cmd "json: statuses and model context contract" python3 - <<'PY' "${JSON_OUT}"
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
statuses = {entry["status"] for entry in data["entries"]}
required = {"pass", "skipped", "warn", "block", "slow", "timeout", "adapter_error"}
missing = required - statuses
if missing:
    raise SystemExit(f"missing statuses: {sorted(missing)}")
for entry in data["entries"]:
    if entry["status"] in {"pass", "skipped", "slow", "timeout", "adapter_error"} and entry["model_context"]:
        raise SystemExit(f"{entry['status']} must not set model_context")
    if entry["status"] in {"warn", "block"} and not entry["model_context"]:
        raise SystemExit(f"{entry['status']} must set model_context")
PY
assert_cmd "schema: status enum covers accepted result states" python3 - <<'PY' "${REPO_DIR}/schemas/hook-status.schema.json"
import json
import sys

schema = json.load(open(sys.argv[1], encoding="utf-8"))
status_enum = set(schema["properties"]["entries"]["items"]["properties"]["status"]["enum"])
required = {"pass", "skipped", "warn", "block", "slow", "timeout", "adapter_error"}
missing = required - status_enum
if missing:
    raise SystemExit(f"schema missing statuses: {sorted(missing)}")
PY

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
  printf '\033[32mAll %d/%d tests passed\033[0m\n' "$PASS" "$TOTAL"
  exit 0
else
  printf '\033[31m%d/%d tests failed\033[0m\n' "$FAIL" "$TOTAL"
  exit 1
fi
