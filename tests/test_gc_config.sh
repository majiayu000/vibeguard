#!/usr/bin/env bash
# VibeGuard GC configuration contract tests.

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
  if grep -qF -- "$expected" <<< "$output"; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"; FAIL=$((FAIL + 1))
  fi
}

assert_occurrences() {
  local output="$1" expected="$2" count="$3" desc="$4"
  local actual
  TOTAL=$((TOTAL + 1))
  actual=$(printf '%s\n' "$output" | grep -cF -- "$expected" || true)
  if [[ "$actual" -eq "$count" ]]; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected $count occurrences of: $expected; got $actual)"; FAIL=$((FAIL + 1))
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

write_config() {
  local path="$1"
  cat > "$path" <<'JSON'
{
  "gc": {
    "log_threshold_mb": 7,
    "archive_retain_months": 11,
    "worktree_max_days": 42,
    "session_metrics_retain_days": 17,
    "learning_window_days": 5,
    "gc_log_max_kb": 2048
  }
}
JSON
}

header "gc config helper"

cfg="${TMP_ROOT}/.vibeguard.json"
write_config "$cfg"

value_out="$(VIBEGUARD_PROJECT_CONFIG="$cfg" bash -c 'source scripts/lib/project_config.sh; vg_config_positive_int VIBEGUARD_GC_LOG_THRESHOLD_MB gc.log_threshold_mb 10')"
assert_contains "$value_out" "7" "helper reads positive integer from .vibeguard.json"

env_out="$(VIBEGUARD_PROJECT_CONFIG="$cfg" VIBEGUARD_GC_LOG_THRESHOLD_MB=9 bash -c 'source scripts/lib/project_config.sh; vg_config_positive_int VIBEGUARD_GC_LOG_THRESHOLD_MB gc.log_threshold_mb 10')"
assert_contains "$env_out" "9" "environment override wins over project config"

missing_out="$(VIBEGUARD_PROJECT_CONFIG="${TMP_ROOT}/missing.json" bash -c 'source scripts/lib/project_config.sh; vg_config_positive_int VIBEGUARD_GC_LOG_THRESHOLD_MB gc.log_threshold_mb 10')"
assert_contains "$missing_out" "10" "missing config falls back to default"

bad_cfg="${TMP_ROOT}/bad-vibeguard.json"
cat > "$bad_cfg" <<'JSON'
{
  "gc": {
    "log_threshold_mb": 0,
    "unexpected_gc_key": 1
  },
  "unknown_top_level": true
}
JSON
invalid_helper_out_file="${TMP_ROOT}/invalid-helper.out"
TOTAL=$((TOTAL + 1))
if VIBEGUARD_PROJECT_CONFIG="$bad_cfg" bash -c 'source scripts/lib/project_config.sh; vg_config_positive_int VIBEGUARD_GC_LOG_THRESHOLD_MB gc.log_threshold_mb 10' > "$invalid_helper_out_file" 2>&1; then
  red "invalid project config fails instead of defaulting"
  FAIL=$((FAIL + 1))
else
  green "invalid project config fails instead of defaulting"
  PASS=$((PASS + 1))
fi
invalid_helper_out="$(<"$invalid_helper_out_file")"
assert_contains "$invalid_helper_out" "VibeGuard project config invalid" "invalid helper read reports project config failure"
assert_contains "$invalid_helper_out" ".gc.log_threshold_mb: expected integer >= 1" "invalid helper read reports bad gc threshold"
assert_contains "$invalid_helper_out" ".gc.unexpected_gc_key: unknown property" "invalid helper read reports unknown gc key"
assert_contains "$invalid_helper_out" ".unknown_top_level: unknown property" "invalid helper read reports unknown top-level key"

header "gc-logs.sh reads project config"

log_dir="${TMP_ROOT}/logs"
mkdir -p "$log_dir"
printf '%s\n' '{"ts":"2026-05-01T00:00:00Z","detail":"current"}' > "${log_dir}/events.jsonl"
gc_logs_out="$(VIBEGUARD_PROJECT_CONFIG="$cfg" VIBEGUARD_LOG_DIR="$log_dir" bash scripts/gc/gc-logs.sh --dry-run)"
assert_contains "$gc_logs_out" "Threshold: 7MB" "gc-logs uses configured threshold"

invalid_gc_logs_out_file="${TMP_ROOT}/invalid-gc-logs.out"
TOTAL=$((TOTAL + 1))
if VIBEGUARD_PROJECT_CONFIG="$bad_cfg" VIBEGUARD_LOG_DIR="$log_dir" bash scripts/gc/gc-logs.sh --dry-run > "$invalid_gc_logs_out_file" 2>&1; then
  red "gc-logs fails on invalid project config"
  FAIL=$((FAIL + 1))
else
  green "gc-logs fails on invalid project config"
  PASS=$((PASS + 1))
fi
invalid_gc_logs_out="$(<"$invalid_gc_logs_out_file")"
assert_contains "$invalid_gc_logs_out" "VibeGuard project config invalid" "gc-logs surfaces invalid project config"

header "gc-worktrees.sh reads project config"

repo="${TMP_ROOT}/repo"
mkdir -p "${repo}/.vibeguard/worktrees/old"
git -C "$repo" init -q
cp "$cfg" "${repo}/.vibeguard.json"
perl -e 'utime(time - 10 * 86400, time - 10 * 86400, $ARGV[0])' "${repo}/.vibeguard/worktrees/old"
worktree_out="$(cd "$repo" && bash "$REPO_DIR/scripts/gc/gc-worktrees.sh" --dry-run)"
assert_contains "$worktree_out" "old [legacy]: 10 days" "gc-worktrees inspects old legacy worktree"
assert_contains "$worktree_out" "reserved" "configured 42-day retention prevents deletion"

legacy_override_out="$(cd "$repo" && VIBEGUARD_WORKTREE_BASE=".vibeguard/worktrees/" bash "$REPO_DIR/scripts/gc/gc-worktrees.sh" --dry-run)"
assert_occurrences "$legacy_override_out" "old [legacy]: 10 days" 1 "gc-worktrees deduplicates legacy base with trailing slash"

relative_repo="${TMP_ROOT}/relative-repo"
relative_base_abs="${TMP_ROOT}/relative-repo.wt"
mkdir -p "${relative_repo}/subdir" "${relative_base_abs}/current"
git -C "$relative_repo" init -q
relative_gc_out="$(
  cd "${relative_repo}/subdir"
  VIBEGUARD_WORKTREE_BASE="../relative-repo.wt" VIBEGUARD_GC_WORKTREE_MAX_DAYS=42 bash "$REPO_DIR/scripts/gc/gc-worktrees.sh" --dry-run
)"
assert_contains "$relative_gc_out" "current: 0 days" "gc-worktrees resolves relative base against repo root"

linux_stat_repo="${TMP_ROOT}/linux-stat-repo"
mkdir -p "${linux_stat_repo}/.vibeguard/worktrees/current" "${TMP_ROOT}/bin"
git -C "$linux_stat_repo" init -q
cat > "${TMP_ROOT}/bin/stat" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-f" ]]; then
  printf '  File: "%s"\n' "${3:-}"
  exit 0
fi
if [[ "${1:-}" == "-c" ]]; then
  date +%s
  exit 0
fi
exec /usr/bin/stat "$@"
SH
chmod +x "${TMP_ROOT}/bin/stat"
linux_stat_out="$(cd "$linux_stat_repo" && PATH="${TMP_ROOT}/bin:$PATH" VIBEGUARD_GC_WORKTREE_MAX_DAYS=42 bash "$REPO_DIR/scripts/gc/gc-worktrees.sh" --dry-run)"
assert_contains "$linux_stat_out" "current [legacy]: 0 days" "gc-worktrees ignores GNU stat -f filesystem output"

header "schema exposes gc contract"

assert_cmd "project config validator syntax is correct" python3 -m py_compile "$REPO_DIR/scripts/lib/project_config_validate.py"
assert_cmd "project config validator accepts valid config" python3 "$REPO_DIR/scripts/lib/project_config_validate.py" --quiet "$cfg" "$REPO_DIR/schemas/vibeguard-project.schema.json"
assert_cmd "project schema accepts gc config" python3 - "$REPO_DIR/schemas/vibeguard-project.schema.json" "$cfg" <<'PY'
import json
import sys

schema_path, cfg_path = sys.argv[1:3]
schema = json.load(open(schema_path))
cfg = json.load(open(cfg_path))
gc_props = schema["properties"]["gc"]["properties"]
for key in cfg["gc"]:
    assert key in gc_props, key
PY

printf '\n==============================\n'
printf 'Total: %s  Pass: \033[32m%s\033[0m  Fail: \033[31m%s\033[0m\n' "$TOTAL" "$PASS" "$FAIL"
printf '==============================\n'

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
