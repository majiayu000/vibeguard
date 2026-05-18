#!/usr/bin/env bash
# VibeGuard eval contract regression tests
#
# Usage: bash tests/test_eval_contract.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR_RESOLVED="$(python3 - <<'PY' "${REPO_DIR}"
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_posix())
PY
)"

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

header "eval runner syntax"
assert_cmd "eval/run_eval.py syntax is correct" python3 -m py_compile "${REPO_DIR}/eval/run_eval.py"
assert_cmd "eval/run_behavior_eval.py syntax is correct" python3 -m py_compile "${REPO_DIR}/eval/run_behavior_eval.py"
assert_cmd "eval support modules syntax is correct" python3 -m py_compile \
  "${REPO_DIR}/eval/dataset.py" \
  "${REPO_DIR}/eval/scoring.py" \
  "${REPO_DIR}/eval/artifacts.py" \
  "${REPO_DIR}/eval/samples.py"

header "dry-run uses repository snapshot by default"
dry_run_out="$(cd "${REPO_DIR}" && python3 eval/run_eval.py --dry-run)"
normalized_out="$(printf '%s' "${dry_run_out}" | tr '\\' '/')"
assert_contains "${normalized_out}" "Dataset source: ${REPO_DIR_RESOLVED}/eval/datasets/v1.jsonl" "dry-run reports versioned dataset source"
assert_contains "${normalized_out}" "Sample digest:" "dry-run reports sample digest"
assert_contains "${normalized_out}" "Rules source: ${REPO_DIR_RESOLVED}/rules/claude-rules" "dry-run reports repository rule source"
assert_contains "${normalized_out}" "Rule digest:" "dry-run reports rule digest"
assert_contains "${normalized_out}" "Core constraint source: ${REPO_DIR_RESOLVED}/claude-md/vibeguard-rules.md" "dry-run reports repository core rules source"
assert_cmd "dry-run does not write mutable eval/results.json" test ! -e "${REPO_DIR}/eval/results.json"

header "behavior eval dry-run"
behavior_dry_run_out="$(cd "${REPO_DIR}" && python3 eval/run_behavior_eval.py --dry-run)"
behavior_normalized_out="$(printf '%s' "${behavior_dry_run_out}" | tr '\\' '/')"
assert_contains "${behavior_normalized_out}" "Behavior dataset source: ${REPO_DIR_RESOLVED}/eval/behavior/datasets/v1.jsonl" "behavior dry-run reports dataset source"
assert_contains "${behavior_normalized_out}" "Behavior sample digest:" "behavior dry-run reports sample digest"
assert_contains "${behavior_normalized_out}" "Required coverage source: ${REPO_DIR_RESOLVED}/eval/behavior/requirements.json" "behavior dry-run reports required coverage source"
assert_contains "${behavior_normalized_out}" "Threshold source: ${REPO_DIR_RESOLVED}/eval/behavior/thresholds.json" "behavior dry-run reports threshold source"

header "dataset contract"
assert_cmd "default dataset loads with schema validation" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from dataset import DEFAULT_DATASET_PATH, load_dataset, sample_set_digest
samples = load_dataset(DEFAULT_DATASET_PATH)
assert len(samples) >= 40
assert len(sample_set_digest(samples)) == 64
assert all("id" in sample and "expected_action" in sample for sample in samples)
' "${REPO_DIR}/eval"

assert_cmd "default behavior dataset loads with schema validation" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from run_behavior_eval import DEFAULT_DATASET_PATH, load_jsonl, sample_digest
samples = load_jsonl(DEFAULT_DATASET_PATH)
assert len(samples) >= 2
assert len(sample_digest(samples)) == 64
assert {sample["platform"] for sample in samples} >= {"claude", "codex"}
' "${REPO_DIR}/eval"

echo
echo "=============================="
printf "Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo "=============================="

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
