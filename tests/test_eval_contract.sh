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
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

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
  "${REPO_DIR}/eval/model_baseline.py" \
  "${REPO_DIR}/eval/sample_ids.py" \
  "${REPO_DIR}/eval/samples.py" \
  "${REPO_DIR}/eval/summarize_runs.py"
assert_cmd "eval.samples package import works from repo root" bash -c "cd '${REPO_DIR}' && python3 - <<'PY'
import eval.samples
assert eval.samples.SAMPLES
PY"

header "dry-run uses repository snapshot by default"
dry_run_out="$(cd "${REPO_DIR}" && python3 eval/run_eval.py --dry-run)"
normalized_out="$(printf '%s' "${dry_run_out}" | tr '\\' '/')"
assert_contains "${normalized_out}" "Dataset source: ${REPO_DIR_RESOLVED}/eval/datasets/v1.jsonl" "dry-run reports versioned dataset source"
assert_contains "${normalized_out}" "Sample digest:" "dry-run reports sample digest"
assert_contains "${normalized_out}" "Rules source: ${REPO_DIR_RESOLVED}/rules/claude-rules" "dry-run reports repository rule source"
assert_contains "${normalized_out}" "Rule digest:" "dry-run reports rule digest"
assert_contains "${normalized_out}" "Core constraint source: ${REPO_DIR_RESOLVED}/claude-md/vibeguard-rules.md" "dry-run reports repository core rules source"
assert_contains "${normalized_out}" "Requested model: haiku" "dry-run reports requested default model"
assert_contains "${normalized_out}" "Resolved model: claude-haiku-4-5-20251001" "dry-run resolves default model from baseline"
assert_contains "${normalized_out}" "Model baseline verified at (UTC): 2026-07-17" "dry-run reports baseline verification date"
assert_contains "${normalized_out}" "Model baseline source: https://platform.claude.com/docs/en/about-claude/models/overview" "dry-run reports baseline source"
assert_cmd "dry-run does not write mutable eval/results.json" test ! -e "${REPO_DIR}/eval/results.json"

sonnet_dry_run_out="$(cd "${REPO_DIR}" && python3 eval/run_eval.py --dry-run --model sonnet)"
assert_contains "${sonnet_dry_run_out}" "Resolved model: claude-sonnet-5" "sonnet alias resolves from baseline"
opus_dry_run_out="$(cd "${REPO_DIR}" && python3 eval/run_eval.py --dry-run --model opus)"
assert_contains "${opus_dry_run_out}" "Resolved model: claude-opus-4-8" "opus alias resolves from baseline"
historical_dry_run_out="$(cd "${REPO_DIR}" && python3 eval/run_eval.py --dry-run --model claude-sonnet-4-6)"
assert_contains "${historical_dry_run_out}" "Resolved model: claude-sonnet-4-6" "full historical model ID passes through"
empty_model_out="$(cd "${REPO_DIR}" && python3 eval/run_eval.py --dry-run --model '' 2>&1 || true)"
assert_cmd "empty requested model fails visibly" bash -c "cd '${REPO_DIR}' && ! python3 eval/run_eval.py --dry-run --model ''"
assert_contains "${empty_model_out}" "Invalid requested model: requested model must not be empty" "empty requested model explains failure"

eval_help_out="$(cd "${REPO_DIR}" && python3 eval/run_eval.py --help)"
assert_contains "${eval_help_out}" "Default model alias: haiku" "eval help reports baseline default"
assert_contains "${eval_help_out}" "haiku -> claude-haiku-4-5-20251001" "eval help reports Haiku alias"
assert_contains "${eval_help_out}" "sonnet -> claude-sonnet-5" "eval help reports Sonnet alias"
assert_contains "${eval_help_out}" "opus -> claude-opus-4-8" "eval help reports Opus alias"

header "behavior eval dry-run"
behavior_dry_run_out="$(cd "${REPO_DIR}" && python3 eval/run_behavior_eval.py --dry-run)"
behavior_normalized_out="$(printf '%s' "${behavior_dry_run_out}" | tr '\\' '/')"
assert_contains "${behavior_normalized_out}" "Behavior dataset source: ${REPO_DIR_RESOLVED}/eval/behavior/datasets/v1.jsonl" "behavior dry-run reports dataset source"
assert_contains "${behavior_normalized_out}" "Behavior sample digest:" "behavior dry-run reports sample digest"
assert_contains "${behavior_normalized_out}" "Required coverage source: ${REPO_DIR_RESOLVED}/eval/behavior/requirements.json" "behavior dry-run reports required coverage source"
assert_contains "${behavior_normalized_out}" "Threshold source: ${REPO_DIR_RESOLVED}/eval/behavior/thresholds.json" "behavior dry-run reports threshold source"
assert_contains "${behavior_normalized_out}" "Requested model: haiku" "behavior dry-run reports requested default model"
assert_contains "${behavior_normalized_out}" "Resolved model: claude-haiku-4-5-20251001" "behavior dry-run resolves shared default model"
behavior_help_out="$(cd "${REPO_DIR}" && python3 eval/run_behavior_eval.py --help)"
assert_contains "${behavior_help_out}" "sonnet -> claude-sonnet-5" "behavior help reports shared alias table"
assert_contains "${behavior_help_out}" "Model baseline verified at (UTC): 2026-07-17" "behavior help reports baseline evidence"

benchmark_help_out="$(cd "${REPO_DIR}" && bash scripts/benchmark.sh --help)"
assert_contains "${benchmark_help_out}" "Default model alias: haiku" "benchmark help reads shared default"
assert_contains "${benchmark_help_out}" "haiku -> claude-haiku-4-5-20251001" "benchmark help reports Haiku alias"
assert_contains "${benchmark_help_out}" "sonnet -> claude-sonnet-5" "benchmark help reports Sonnet alias"
assert_contains "${benchmark_help_out}" "opus -> claude-opus-4-8" "benchmark help reports Opus alias"
assert_contains "${benchmark_help_out}" "Model baseline verified at (UTC): 2026-07-17" "benchmark help reports baseline evidence"

header "eval summary index"
assert_cmd "eval run summary schema loads" python3 -c '
import json
import sys
schema = json.load(open(sys.argv[1], encoding="utf-8"))
assert schema["properties"]["kind"]["enum"] == ["behavior", "model"]
assert "pass_rate" in schema["properties"]
assert "detection_rate" in schema["properties"]
' "${REPO_DIR}/schemas/eval-run-summary.schema.json"

mkdir -p "${TMP_DIR}/runs"
cat > "${TMP_DIR}/runs/index.jsonl" <<'JSONL'
{"schema_version":1,"kind":"behavior","score_type":"deterministic","timestamp":"2026-01-01T00:00:00Z","run_id":"behavior-run","artifact_path":"/tmp/behavior/results.json","commit":"abc123","dataset_source":"/repo/eval/behavior/datasets/v1.jsonl","dataset_digest":"behaviordigest","sample_count":2,"scorer_version":"behavior-e2e-v1","verdict":"fail","failure_count":1,"pass_rate":100.0,"coverage_rate":100.0,"slice_failures":[]}
{"schema_version":1,"kind":"model","score_type":"model_backed","timestamp":"2026-01-01T00:01:00Z","run_id":"model-run","artifact_path":"/tmp/model/results.json","commit":"abc123","dataset_source":"/repo/eval/datasets/v1.jsonl","dataset_digest":"modeldigest","sample_set_digest":"sampledigest","sample_count":40,"scorer_version":"structured-json-v1","model":"test-model","rule_digest":"ruledigest","skipped_count":0,"detection_rate":95.0,"false_positive_rate":2.5,"ece":8.0,"true_positive_total":38,"true_positive_detected":36,"false_positive_total":2,"false_positive_count":0}
JSONL
summary_out="$(cd "${REPO_DIR}" && python3 eval/summarize_runs.py --runs-dir "${TMP_DIR}/runs" --last 2)"
assert_contains "${summary_out}" "behavior deterministic" "summary reader keeps deterministic behavior scores separate"
assert_contains "${summary_out}" "verdict=fail" "summary reader shows behavior verdict"
assert_contains "${summary_out}" "failures=1" "summary reader shows behavior failure count"
assert_contains "${summary_out}" "model model-backed" "summary reader keeps model-backed scores separate"
assert_contains "${summary_out}" "rules=ruledigest" "summary reader shows rule digest for model evals"

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
