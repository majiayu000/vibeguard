#!/usr/bin/env bash
# VibeGuard GC log archiving tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

PASS=0
FAIL=0
TOTAL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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
  local output="$1" unexpected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if ! printf '%s' "$output" | grep -qF -- "$unexpected"; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (unexpectedly contains: $unexpected)"; FAIL=$((FAIL + 1))
  fi
}

assert_cmd() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc"; FAIL=$((FAIL + 1))
  fi
}

current_ts() {
  date -u '+%Y-%m-01T00:00:00Z'
}

file_mode() {
  local path="$1"
  local mode
  mode=$(stat -f '%Lp' "$path" 2>/dev/null || true)
  if [[ "$mode" =~ ^[0-9]+$ ]]; then
    echo "$mode"
    return 0
  fi
  mode=$(stat -c '%a' "$path" 2>/dev/null || true)
  if [[ "$mode" =~ ^[0-9]+$ ]]; then
    echo "$mode"
    return 0
  fi
  echo ""
}

write_fixture_log() {
  local log_dir="$1"
  mkdir -p "$log_dir"
  cat > "${log_dir}/events.jsonl" <<EOF
{"ts":"2024-01-01T00:00:00Z","detail":"old-line"}
{"ts":"$(current_ts)","detail":"current-line"}
EOF
}

run_gc() {
  local log_dir="$1"
  shift
  VIBEGUARD_LOG_DIR="$log_dir" bash scripts/gc/gc-logs.sh --threshold 0 "$@"
}

header "gc-logs.sh dry-run is read-only"

dry_dir="${TMP_ROOT}/dry"
write_fixture_log "$dry_dir"
before_sha="$(shasum -a 256 "${dry_dir}/events.jsonl" | awk '{print $1}')"
dry_out="$(run_gc "$dry_dir" --dry-run --retain 60)"
after_sha="$(shasum -a 256 "${dry_dir}/events.jsonl" | awk '{print $1}')"

assert_contains "$dry_out" "[DRY-RUN] Archive 1" "dry-run reports the archive plan"
assert_cmd "dry-run does not create archive files" bash -c "! find '${dry_dir}/archive' -type f 2>/dev/null | grep -q ."
assert_cmd "dry-run keeps events.jsonl unchanged" test "$before_sha" = "$after_sha"

header "gc-logs.sh archives old months atomically"

archive_dir="${TMP_ROOT}/archive"
write_fixture_log "$archive_dir"
archive_out="$(run_gc "$archive_dir" --retain 60)"
remaining="$(cat "${archive_dir}/events.jsonl")"
archived="$(gzip -dc "${archive_dir}/archive/events-2024-01.jsonl.gz")"

assert_contains "$archive_out" "archive 1 items, retain 1 items" "archive run reports moved and retained counts"
assert_contains "$remaining" "current-line" "current month line remains in events.jsonl"
assert_not_contains "$remaining" "old-line" "old month line is removed from events.jsonl"
assert_contains "$archived" "old-line" "old month line is archived"
assert_cmd "events.jsonl remains mode 600" test "$(file_mode "${archive_dir}/events.jsonl")" = "600"

header "gc-logs.sh waits for active writer lock"

race_dir="${TMP_ROOT}/race"
mkdir -p "$race_dir"
cat > "${race_dir}/events.jsonl" <<EOF
{"ts":"2024-01-01T00:00:00Z","detail":"race-old-line"}
EOF
mkdir "${race_dir}/events.jsonl.lock.d"
(
  sleep 0.2
  printf '%s\n' "{\"ts\":\"$(current_ts)\",\"detail\":\"concurrent-current-line\"}" >> "${race_dir}/events.jsonl"
  rmdir "${race_dir}/events.jsonl.lock.d"
) &
writer_pid=$!
race_out="$(run_gc "$race_dir" --retain 60)"
wait "$writer_pid"
race_remaining="$(cat "${race_dir}/events.jsonl")"
race_archived="$(gzip -dc "${race_dir}/archive/events-2024-01.jsonl.gz")"

assert_contains "$race_out" "archive 1 items, retain 1 items" "race run includes the concurrent append"
assert_contains "$race_remaining" "concurrent-current-line" "concurrent current-month append is retained"
assert_not_contains "$race_remaining" "race-old-line" "race old-month line is removed from events.jsonl"
assert_contains "$race_archived" "race-old-line" "race old-month line is archived"
assert_cmd "GC lock directory is released" test ! -e "${race_dir}/events.jsonl.lock.d"

header "gc-logs.sh archives project logs recursively"

project_root="${TMP_ROOT}/project-root"
project_log_dir="${project_root}/projects/abc123"
write_fixture_log "$project_log_dir"
project_out="$(run_gc "$project_root" --retain 60)"
project_remaining="$(cat "${project_log_dir}/events.jsonl")"
project_archived="$(gzip -dc "${project_log_dir}/archive/events-2024-01.jsonl.gz")"

assert_contains "$project_out" "Processing project log" "project log target is discovered"
assert_contains "$project_out" "archive 1 items, retain 1 items" "project log archive reports moved and retained counts"
assert_contains "$project_remaining" "current-line" "project current-month line remains in events.jsonl"
assert_not_contains "$project_remaining" "old-line" "project old-month line is removed from events.jsonl"
assert_contains "$project_archived" "old-line" "project old-month line is archived"
assert_cmd "project events.jsonl remains mode 600" test "$(file_mode "${project_log_dir}/events.jsonl")" = "600"

printf '\n==============================\n'
printf 'Total: %s  Pass: \033[32m%s\033[0m  Fail: \033[31m%s\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
printf '==============================\n'

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
