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
  if printf '%s' "$output" | grep -qF -- "$expected"; then
    green "$desc"; PASS=$((PASS + 1))
  else
    red "$desc (expected to contain: $expected)"; FAIL=$((FAIL + 1))
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

header "gc-logs.sh reads project config"

log_dir="${TMP_ROOT}/logs"
mkdir -p "$log_dir"
printf '%s\n' '{"ts":"2026-05-01T00:00:00Z","detail":"current"}' > "${log_dir}/events.jsonl"
gc_logs_out="$(VIBEGUARD_PROJECT_CONFIG="$cfg" VIBEGUARD_LOG_DIR="$log_dir" bash scripts/gc/gc-logs.sh --dry-run)"
assert_contains "$gc_logs_out" "Threshold: 7MB" "gc-logs uses configured threshold"

header "gc-worktrees.sh reads project config"

repo="${TMP_ROOT}/repo"
mkdir -p "${repo}/.vibeguard/worktrees/old"
git -C "$repo" init -q
cp "$cfg" "${repo}/.vibeguard.json"
perl -e 'utime(time - 10 * 86400, time - 10 * 86400, $ARGV[0])' "${repo}/.vibeguard/worktrees/old"
worktree_out="$(cd "$repo" && bash "$REPO_DIR/scripts/gc/gc-worktrees.sh" --dry-run)"
assert_contains "$worktree_out" "old: 10 days" "gc-worktrees inspects old worktree"
assert_contains "$worktree_out" "reserved" "configured 42-day retention prevents deletion"

header "schema exposes gc contract"

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
