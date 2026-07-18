#!/usr/bin/env bash
# VibeGuard GC rotation tests: codex-wrapper.jsonl coverage, current-month
# line cap, archive .gz clobber protection, and stale marker cleanup.

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

assert_true() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc"; FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" == "$expected" ]]; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected: $expected, actual: $actual)"; FAIL=$((FAIL + 1))
  fi
}

current_month() { date +%Y-%m; }
prev_month() {
  date -v-1m +%Y-%m 2>/dev/null || date -d "1 month ago" +%Y-%m
}

write_events() {
  # write_events <file> <month> <count> [pad]
  local file="$1" month="$2" count="$3" pad="${4:-}" i
  for ((i = 1; i <= count; i++)); do
    printf '{"ts": "%s-01T00:00:%02dZ", "hook": "test", "pad": "%s", "seq": %d}\n' \
      "$month" $((i % 60)) "$pad" "$i" >> "$file"
  done
}

fresh_log_dir() {
  local dir="${TMP_ROOT}/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

header "codex-wrapper.jsonl is covered by log GC"
LOG_DIR="$(fresh_log_dir wrapper)"
write_events "${LOG_DIR}/codex-wrapper.jsonl" "$(prev_month)" 20
write_events "${LOG_DIR}/codex-wrapper.jsonl" "$(current_month)" 5
out="$(VIBEGUARD_LOG_DIR="$LOG_DIR" bash scripts/gc/gc-logs.sh --threshold 1)"
assert_contains "$out" "codex wrapper log" "wrapper log is processed"
assert_true "previous-month wrapper archive created" \
  ls "${LOG_DIR}/archive/codex-wrapper-$(prev_month)".jsonl.gz
assert_eq "$(grep -c '' "${LOG_DIR}/codex-wrapper.jsonl")" "5" \
  "wrapper main file retains only current-month lines"

header "current-month byte cap archives overflow"
LOG_DIR="$(fresh_log_dir cap)"
# 20 lines of ~260 bytes each (~5KB total) against a 1KB cap: only the newest
# few lines fit the budget, the rest must be archived.
pad="$(printf 'x%.0s' {1..200})"
write_events "${LOG_DIR}/events.jsonl" "$(current_month)" 20 "$pad"
out="$(VIBEGUARD_LOG_DIR="$LOG_DIR" VIBEGUARD_GC_CURRENT_MONTH_MAX_KB=1 \
  bash scripts/gc/gc-logs.sh --threshold 1)"
retained="$(grep -c '' "${LOG_DIR}/events.jsonl")"
assert_true "main file is trimmed below the original 20 lines" \
  test "$retained" -lt 20
assert_true "main file still retains at least one line" \
  test "$retained" -ge 1
assert_true "main file stays within the byte cap" \
  test "$(wc -c < "${LOG_DIR}/events.jsonl" | tr -d ' ')" -le 1024
assert_contains "$(zcat < "$(ls "${LOG_DIR}/archive/events-$(current_month)-"*.jsonl.gz)" )" \
  '"seq": 1}' "overflow archive holds the oldest lines"
assert_eq "$(grep -c '"seq": 20}' "${LOG_DIR}/events.jsonl")" "1" \
  "newest line stays in the main file"

header "existing month .gz archive is not clobbered"
LOG_DIR="$(fresh_log_dir clobber)"
mkdir -p "${LOG_DIR}/archive"
printf '{"ts": "%s-01T00:00:00Z", "hook": "old-archived"}\n' "$(prev_month)" \
  > "${LOG_DIR}/archive/events-$(prev_month).jsonl"
gzip "${LOG_DIR}/archive/events-$(prev_month).jsonl"
write_events "${LOG_DIR}/events.jsonl" "$(prev_month)" 3
write_events "${LOG_DIR}/events.jsonl" "$(current_month)" 2
VIBEGUARD_LOG_DIR="$LOG_DIR" bash scripts/gc/gc-logs.sh --threshold 1 >/dev/null
assert_contains "$(zcat < "${LOG_DIR}/archive/events-$(prev_month).jsonl.gz")" \
  "old-archived" "pre-existing archive content survives a re-run"
assert_true "late entries land in a run-stamped sibling archive" \
  ls "${LOG_DIR}/archive/events-$(prev_month)-"*.jsonl.gz

header "stale learn-metrics markers are cleaned"
LOG_DIR="$(fresh_log_dir markers)"
write_events "${LOG_DIR}/events.jsonl" "$(current_month)" 1
touch "${LOG_DIR}/.learn_metrics_truncated_fresh"
touch -mt "$(date -v-3d +%Y%m%d%H%M 2>/dev/null || date -d '3 days ago' +%Y%m%d%H%M)" \
  "${LOG_DIR}/.learn_metrics_truncated_old"
out="$(VIBEGUARD_LOG_DIR="$LOG_DIR" bash scripts/gc/gc-logs.sh)"
assert_contains "$out" "Removed 1 stale learn-metrics markers" \
  "stale marker cleanup reports the removal"
assert_true "fresh marker is kept" test -f "${LOG_DIR}/.learn_metrics_truncated_fresh"
assert_true "old marker is deleted" test ! -f "${LOG_DIR}/.learn_metrics_truncated_old"

header "dry-run leaves everything untouched"
LOG_DIR="$(fresh_log_dir dryrun)"
write_events "${LOG_DIR}/events.jsonl" "$(prev_month)" 3
touch -mt "$(date -v-3d +%Y%m%d%H%M 2>/dev/null || date -d '3 days ago' +%Y%m%d%H%M)" \
  "${LOG_DIR}/.learn_metrics_truncated_old"
out="$(VIBEGUARD_LOG_DIR="$LOG_DIR" bash scripts/gc/gc-logs.sh --threshold 1 --dry-run)"
assert_contains "$out" "[DRY-RUN]" "dry-run reports planned actions"
assert_eq "$(grep -c '' "${LOG_DIR}/events.jsonl")" "3" "dry-run keeps the main file intact"
assert_true "dry-run keeps stale markers" test -f "${LOG_DIR}/.learn_metrics_truncated_old"

echo
echo "=============================="
echo "Total: $TOTAL  Pass: $PASS  Fail: $FAIL"
echo "=============================="
[[ "$FAIL" -eq 0 ]]
