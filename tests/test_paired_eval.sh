#!/usr/bin/env bash
# VibeGuard paired model-eval deterministic regression tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

python3 -m py_compile "${REPO_DIR}/eval/run_paired_eval.py"
python3 "${REPO_DIR}/eval/test_paired_eval.py"

dry_run_out="$(
  cd "${REPO_DIR}"
  env -u ANTHROPIC_API_KEY python3 eval/run_paired_eval.py \
    --candidate U-32 \
    --placebo-candidate U-31 \
    --dry-run \
    --artifact-root "${TMP_DIR}/runs"
)"

grep -qF "Paired runs: target-with, target-without, non-target-with, non-target-without" <<<"${dry_run_out}"
grep -qF "Removal assertions: file_set=pass, presence=pass, definition_site=pass, file_diff=pass, definition_count=pass" <<<"${dry_run_out}"
grep -qF "Cross references (13):" <<<"${dry_run_out}"
grep -qF "Empty-shell rule files:" <<<"${dry_run_out}"
grep -qF "Target samples: 0" <<<"${dry_run_out}"
grep -qF "Non-target samples: 30" <<<"${dry_run_out}"
grep -qF "Producer model:" <<<"${dry_run_out}"
grep -qF "Judge model: not required for dry-run" <<<"${dry_run_out}"
grep -qF "Judge prompt digest:" <<<"${dry_run_out}"
grep -qF "Rule text characters: with=" <<<"${dry_run_out}"
grep -qF "Placebo candidate: U-31" <<<"${dry_run_out}"
grep -qF "Verdict: not produced in dry-run" <<<"${dry_run_out}"
test ! -e "${TMP_DIR}/runs"

set +e
real_out="$(
  cd "${REPO_DIR}"
  python3 eval/run_paired_eval.py \
    --candidate U-32 \
    --artifact-root "${TMP_DIR}/real-runs" 2>&1
)"
real_rc=$?
set -e
test "${real_rc}" -ne 0
grep -qF "real runs require --judge-model" <<<"${real_out}"

printf 'paired eval regression tests passed\n'
