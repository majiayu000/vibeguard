#!/usr/bin/env bash
# VibeGuard Learn W-37 success/failure trajectory tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

PASS=0
FAIL=0
TOTAL=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }
header(){ printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

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

assert_fails() {
  local desc="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then
    red "$desc (expected failure)"; FAIL=$((FAIL + 1))
  else
    green "$desc"; PASS=$((PASS + 1))
  fi
}

store="${TMP_DIR}/learn-trajectories.jsonl"

header "learn W-37 trajectories"
assert_cmd "learn trajectory helper compiles" python3 -m py_compile scripts/learn/trajectory.py

assert_fails "successful trajectory requires explicit low-friction flag" python3 scripts/learn/trajectory.py \
  --store "$store" \
  record \
  --task-class rust-hook-fix \
  --outcome success \
  --evidence "passed in one local verification"

python3 scripts/learn/trajectory.py \
  --store "$store" \
  record \
  --task-class rust-hook-fix \
  --outcome failure \
  --evidence "previous attempt missed failing setup test" \
  --failure-lesson "run tests/test_setup.sh after hook state changes" \
  --signal-id lrn_failure_001 \
  --verification-command "bash tests/test_setup.sh" >/dev/null

python3 scripts/learn/trajectory.py \
  --store "$store" \
  record \
  --task-class rust-hook-fix \
  --outcome success \
  --low-friction \
  --evidence "later attempt passed focused hook test and setup test without churn" \
  --verification-command "bash tests/hooks/test_post_edit_guard_basic.sh" \
  --verification-command "bash tests/test_setup.sh" >/dev/null

preview="${TMP_DIR}/trajectory-preview.json"
python3 scripts/learn/trajectory.py \
  --store "$store" \
  preview \
  --task-class rust-hook-fix > "$preview"

assert_cmd "trajectory preview shows success and failure evidence together" python3 - "$preview" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert data["combined_evidence_available"] is True, data
assert len(data["success_trajectories"]) == 1, data
assert len(data["failure_trajectories"]) == 1, data
success = data["success_trajectories"][0]
failure = data["failure_trajectories"][0]
assert success["outcome_flags"]["success"] is True, success
assert success["outcome_flags"]["low_friction"] is True, success
assert failure["outcome_flags"]["failure"] is True, failure
assert failure["failure_lesson"], failure
PY

assert_fails "success-only retrieval is rejected when failure lessons exist" python3 scripts/learn/trajectory.py \
  --store "$store" \
  preview \
  --task-class rust-hook-fix \
  --success-only

assert_cmd "success record does not overwrite failure record" bash -c "test \"\$(wc -l < '$store' | tr -d ' ')\" = 2"

printf "\n==============================\n"
printf "Total: %d  Pass: %d  Fail: %d\n" "$TOTAL" "$PASS" "$FAIL"
printf "==============================\n"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
