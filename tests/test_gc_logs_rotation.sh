#!/usr/bin/env bash
# VibeGuard GC rotation regression tests for GH659 B-001 through B-007.

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

write_large_events() {
  local file="$1" month="$2" count="$3" pad_size="$4"
  _TEST_FILE="$file" _TEST_MONTH="$month" _TEST_COUNT="$count" \
    _TEST_PAD_SIZE="$pad_size" python3 <<'PY'
import json
import os

with open(os.environ['_TEST_FILE'], 'w', encoding='utf-8') as output:
    pad = 'x' * int(os.environ['_TEST_PAD_SIZE'])
    for seq in range(1, int(os.environ['_TEST_COUNT']) + 1):
        output.write(json.dumps({
            'ts': f"{os.environ['_TEST_MONTH']}-01T00:00:00Z",
            'hook': 'test',
            'pad': pad,
            'seq': seq,
        }, separators=(',', ':')) + '\n')
PY
}

snapshot_tree() {
  _TEST_ROOT="$1" python3 <<'PY'
import hashlib
import os

root = os.environ['_TEST_ROOT']
for current, dirs, files in os.walk(root):
    dirs.sort()
    files.sort()
    relative = os.path.relpath(current, root)
    print(f'D {relative}')
    for name in files:
        path = os.path.join(current, name)
        with open(path, 'rb') as stream:
            digest = hashlib.sha256(stream.read()).hexdigest()
        stat = os.stat(path, follow_symlinks=False)
        print(f'F {os.path.relpath(path, root)} {stat.st_mode:o} {stat.st_mtime_ns} {digest}')
PY
}

fresh_log_dir() {
  local dir="${TMP_ROOT}/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

header "B-001 codex wrapper archives use their own prefix"
LOG_DIR="$(fresh_log_dir wrapper)"
write_events "${LOG_DIR}/codex-wrapper.jsonl" "$(prev_month)" 20
write_events "${LOG_DIR}/codex-wrapper.jsonl" "$(current_month)" 5
out="$(VIBEGUARD_LOG_DIR="$LOG_DIR" bash scripts/gc/gc-logs.sh --threshold 1)"
assert_contains "$out" "codex wrapper log" "wrapper log is processed"
assert_true "previous-month wrapper archive is compressed" \
  test -f "${LOG_DIR}/archive/codex-wrapper-$(prev_month).jsonl.gz"
assert_eq "$(grep -c '' "${LOG_DIR}/codex-wrapper.jsonl")" "5" \
  "wrapper live file contains the current-month records"

header "B-002 internal byte cap archives overflow below the threshold"
LOG_DIR="$(fresh_log_dir cap)"
write_large_events "${LOG_DIR}/events.jsonl" "$(current_month)" 10000 900
original_bytes="$(wc -c < "${LOG_DIR}/events.jsonl" | tr -d '[:space:]')"
assert_true "fixture is above 8192 KiB" test "$original_bytes" -gt $((8192 * 1024))
assert_true "fixture is below the configured 20 MiB threshold" test "$original_bytes" -lt $((20 * 1024 * 1024))
VIBEGUARD_LOG_DIR="$LOG_DIR" bash scripts/gc/gc-logs.sh --threshold 20 >/dev/null
retained_bytes="$(wc -c < "${LOG_DIR}/events.jsonl" | tr -d '[:space:]')"
assert_true "live file is reduced to the internal cap" test "$retained_bytes" -le $((8192 * 1024))
assert_true "overflow archive contains the oldest record" \
  sh -c 'gzip -cd "$1" | grep -q '"'"'"seq":1'"'"'' _ \
  "$(find "${LOG_DIR}/archive" -name 'events-*.jsonl.gz' -print -quit)"
assert_true "live file retains the newest record" \
  grep -q '"seq":10000' "${LOG_DIR}/events.jsonl"

header "B-002 oversized newest record remains as the explicit exception"
LOG_DIR="$(fresh_log_dir oversized-newest)"
write_events "${LOG_DIR}/events.jsonl" "$(current_month)" 2
_TEST_FILE="${LOG_DIR}/events.jsonl" _TEST_MONTH="$(current_month)" python3 <<'PY'
import json
import os

with open(os.environ['_TEST_FILE'], 'a', encoding='utf-8') as output:
    output.write(json.dumps({
        'ts': f"{os.environ['_TEST_MONTH']}-01T00:00:59Z",
        'hook': 'test',
        'pad': 'z' * (9 * 1024 * 1024),
        'seq': 3,
    }, separators=(',', ':')) + '\n')
PY
VIBEGUARD_LOG_DIR="$LOG_DIR" bash scripts/gc/gc-logs.sh --threshold 20 >/dev/null
assert_eq "$(wc -l < "${LOG_DIR}/events.jsonl" | tr -d '[:space:]')" "1" \
  "only one complete line remains live"
assert_true "the oversized newest line remains live" \
  grep -q '"seq":3' "${LOG_DIR}/events.jsonl"
assert_true "older same-month records are archived" \
  sh -c 'gzip -cd "$1" | grep -q '"'"'"seq": 1'"'"'' _ \
  "$(find "${LOG_DIR}/archive" -name 'events-*.jsonl.gz' -print -quit)"

header "B-003 canonical and run-stamped archives are never clobbered"
LOG_DIR="$(fresh_log_dir collisions)"
mkdir -p "${LOG_DIR}/archive"
printf 'canonical sentinel\n' | gzip > "${LOG_DIR}/archive/events-$(prev_month).jsonl.gz"
printf 'collision sentinel\n' | gzip > "${LOG_DIR}/archive/events-$(prev_month)-fixed.jsonl.gz"
printf 'plain collision sentinel\n' > "${LOG_DIR}/archive/events-$(prev_month)-fixed-1.jsonl"
canonical_before="$(shasum -a 256 "${LOG_DIR}/archive/events-$(prev_month).jsonl.gz")"
collision_before="$(shasum -a 256 "${LOG_DIR}/archive/events-$(prev_month)-fixed.jsonl.gz")"
plain_before="$(shasum -a 256 "${LOG_DIR}/archive/events-$(prev_month)-fixed-1.jsonl")"
write_events "${LOG_DIR}/events.jsonl" "$(prev_month)" 3
write_events "${LOG_DIR}/events.jsonl" "$(current_month)" 2
_GC_RUN_STAMP=fixed VIBEGUARD_LOG_DIR="$LOG_DIR" \
  bash scripts/gc/gc-logs.sh --threshold 1 >/dev/null
assert_eq "$(shasum -a 256 "${LOG_DIR}/archive/events-$(prev_month).jsonl.gz")" \
  "$canonical_before" "canonical gzip remains byte-identical"
assert_eq "$(shasum -a 256 "${LOG_DIR}/archive/events-$(prev_month)-fixed.jsonl.gz")" \
  "$collision_before" "run-stamped gzip remains byte-identical"
assert_eq "$(shasum -a 256 "${LOG_DIR}/archive/events-$(prev_month)-fixed-1.jsonl")" \
  "$plain_before" "colliding plain JSONL remains byte-identical"
assert_true "allocator advances past gzip and JSONL collisions" \
  test -f "${LOG_DIR}/archive/events-$(prev_month)-fixed-2.jsonl.gz"

header "B-004 stale, fresh, and exact-boundary markers"
LOG_DIR="$(fresh_log_dir markers)"
touch "${LOG_DIR}/.learn_metrics_truncated_old"
touch "${LOG_DIR}/.learn_metrics_truncated_boundary"
touch "${LOG_DIR}/.learn_metrics_truncated_fresh"
_TEST_ROOT="$LOG_DIR" python3 <<'PY'
import os

root = os.environ['_TEST_ROOT']
now = 2_000_000_000
cutoff = now - 86400
os.utime(os.path.join(root, '.learn_metrics_truncated_old'), (cutoff - 1, cutoff - 1))
os.utime(os.path.join(root, '.learn_metrics_truncated_boundary'), (cutoff, cutoff))
os.utime(os.path.join(root, '.learn_metrics_truncated_fresh'), (cutoff + 1, cutoff + 1))
PY
out="$(_GC_NOW_EPOCH=2000000000 VIBEGUARD_LOG_DIR="$LOG_DIR" bash scripts/gc/gc-logs.sh)"
assert_contains "$out" "Removed 1 stale learn-metrics markers" "one stale marker is reported"
assert_true "older-than-one-day marker is removed" test ! -f "${LOG_DIR}/.learn_metrics_truncated_old"
assert_true "exact-boundary marker is retained" test -f "${LOG_DIR}/.learn_metrics_truncated_boundary"
assert_true "fresh marker is retained" test -f "${LOG_DIR}/.learn_metrics_truncated_fresh"

header "B-006 dry-run reports archive, compression, and marker actions without mutation"
LOG_DIR="$(fresh_log_dir dryrun-actions)"
write_events "${LOG_DIR}/events.jsonl" "$(prev_month)" 3
write_events "${LOG_DIR}/events.jsonl" "$(current_month)" 1
touch "${LOG_DIR}/.learn_metrics_truncated_old"
_TEST_FILE="${LOG_DIR}/.learn_metrics_truncated_old" python3 <<'PY'
import os
os.utime(os.environ['_TEST_FILE'], (1_999_900_000, 1_999_900_000))
PY
before="$(snapshot_tree "$LOG_DIR")"
out="$(_GC_NOW_EPOCH=2000000000 VIBEGUARD_LOG_DIR="$LOG_DIR" \
  bash scripts/gc/gc-logs.sh --threshold 1 --dry-run)"
after="$(snapshot_tree "$LOG_DIR")"
assert_eq "$after" "$before" "dry-run leaves the complete filesystem snapshot unchanged"
assert_true "dry-run does not create an archive directory" test ! -e "${LOG_DIR}/archive"
assert_contains "$out" "[DRY-RUN] Archive" "dry-run reports archive writes"
assert_contains "$out" "[DRY-RUN] Compress archive" "dry-run reports compression"
assert_contains "$out" "[DRY-RUN] Delete stale learn-metrics marker" "dry-run reports marker deletion"

header "B-006 and B-007 retention covers both archive prefixes"
LOG_DIR="$(fresh_log_dir retention)"
mkdir -p "${LOG_DIR}/archive"
write_events "${LOG_DIR}/events.jsonl" "$(current_month)" 1
write_events "${LOG_DIR}/codex-wrapper.jsonl" "$(current_month)" 1
for prefix in events codex-wrapper; do
  printf 'expired\n' | gzip > "${LOG_DIR}/archive/${prefix}-2000-01.jsonl.gz"
  printf 'current\n' | gzip > "${LOG_DIR}/archive/${prefix}-$(current_month).jsonl.gz"
done
before="$(snapshot_tree "$LOG_DIR")"
out="$(VIBEGUARD_LOG_DIR="$LOG_DIR" bash scripts/gc/gc-logs.sh --threshold 20 --dry-run)"
after="$(snapshot_tree "$LOG_DIR")"
assert_eq "$after" "$before" "retention dry-run is non-mutating"
assert_contains "$out" "events-2000-01.jsonl.gz" "dry-run reports expired events archive"
assert_contains "$out" "codex-wrapper-2000-01.jsonl.gz" "dry-run reports expired wrapper archive"
VIBEGUARD_LOG_DIR="$LOG_DIR" bash scripts/gc/gc-logs.sh --threshold 20 >/dev/null
assert_true "expired events archive is deleted" test ! -f "${LOG_DIR}/archive/events-2000-01.jsonl.gz"
assert_true "expired wrapper archive is deleted" test ! -f "${LOG_DIR}/archive/codex-wrapper-2000-01.jsonl.gz"
assert_true "unexpired events archive is retained" test -f "${LOG_DIR}/archive/events-$(current_month).jsonl.gz"
assert_true "unexpired wrapper archive is retained" test -f "${LOG_DIR}/archive/codex-wrapper-$(current_month).jsonl.gz"

echo
echo "=============================="
echo "Total: $TOTAL  Pass: $PASS  Fail: $FAIL"
echo "=============================="
[[ "$FAIL" -eq 0 ]]
