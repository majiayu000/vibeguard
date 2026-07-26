#!/usr/bin/env bash
# VibeGuard paired model-eval deterministic regression tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

python3 -m py_compile "${REPO_DIR}/eval/run_paired_eval.py"
python3 "${REPO_DIR}/eval/test_paired_eval.py"
PYTHONPATH="${REPO_DIR}/eval" python3 - <<'PY'
import json
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import paired_execution as execution
import run_paired_eval as paired


class FinalReviewRegressionTest(unittest.TestCase):
    def test_paired_runner_pins_implementation_and_model_baseline(self):
        paths = {
            path.resolve()
            for path in paired._evaluated_provenance_paths(
                rules_dir=paired.DEFAULT_RULES_DIR,
                core_file=paired.DEFAULT_CORE_RULES_FILE,
                target_path=paired.DEFAULT_TARGET_DATASET,
                non_target_path=paired.DEFAULT_NON_TARGET_DATASET,
                thresholds_path=paired.DEFAULT_THRESHOLDS,
            )
        }
        expected = {
            paired.REPO_ROOT / "eval" / name
            for name in (
                "artifacts.py",
                "dataset.py",
                "model_baseline.json",
                "model_baseline.py",
                "paired_execution.py",
                "paired_provenance.py",
                "paired_runner.py",
                "paired_scoring.py",
                "run_eval.py",
                "run_paired_eval.py",
                "sample_ids.py",
                "scoring.py",
            )
        }
        expected.update({
            paired.REPO_ROOT / "scripts" / "lib" / name
            for name in (
                "hooks_manifest.py",
                "project_schema_contract.py",
                "vibeguard_manifest.py",
            )
        })
        self.assertTrue(expected.issubset(paths), expected - paths)

    def test_cli_pins_commit_before_local_evaluator_imports(self):
        source = (
            paired.REPO_ROOT / "eval" / "run_paired_eval.py"
        ).read_text(encoding="utf-8")
        capture_index = source.index("_capture_startup_commit(REPO_ROOT)")
        first_local_import_index = source.index("from paired_runner import")
        self.assertLess(capture_index, first_local_import_index)

    def test_evaluated_inputs_must_match_the_pinned_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            input_path = repo / "rules.md"
            input_path.write_text("committed\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "rules.md"], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo),
                    "-c",
                    "user.name=VibeGuard Test",
                    "-c",
                    "user.email=test@example.com",
                    "commit",
                    "-qm",
                    "fixture",
                ],
                check=True,
            )
            pinned = paired.pin_evaluated_inputs([input_path], repo_root=repo)
            self.assertEqual(len(pinned), 40)
            input_path.write_text("dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(
                paired.PairedProvenanceError, "uncommitted"
            ):
                paired.pin_evaluated_inputs(
                    [input_path], expected_commit=pinned, repo_root=repo
                )
            input_path.write_text("committed\n", encoding="utf-8")
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo),
                    "update-index",
                    "--assume-unchanged",
                    "rules.md",
                ],
                check=True,
            )
            input_path.write_text("hidden dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(
                paired.PairedProvenanceError, "differs from commit"
            ):
                paired.pin_evaluated_inputs(
                    [input_path], expected_commit=pinned, repo_root=repo
                )

    def test_semantically_related_placebo_pair_is_rejected(self):
        with self.assertRaisesRegex(
            paired.PairedEvalError, "not explicitly approved"
        ):
            paired.validate_placebo_candidate(
                "RS-03",
                "TASTE-ASYNC-UNWRAP",
                100,
                100,
                0.25,
            )

    def test_empty_non_target_axis_is_inconclusive(self):
        thresholds = {
            "min_non_target_samples": 0,
            "max_non_target_drop": 0.0,
            "max_skip_rate": 0.1,
            "max_skip_delta": 0.05,
        }
        axis = paired.compute_non_target_axis([], 0, thresholds)
        self.assertEqual(axis["verdict"], "inconclusive")
        self.assertIn("empty", " ".join(axis["reasons"]))

    def test_zero_minimum_sample_threshold_is_rejected(self):
        thresholds = {
            "min_target_samples": 5,
            "min_non_target_samples": 0,
            "min_target_delta": 0.0,
            "max_non_target_drop": 0.0,
            "max_skip_rate": 0.1,
            "max_skip_delta": 0.05,
            "max_cross_refs": 4,
            "max_placebo_length_ratio": 0.25,
            "calibrated": True,
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "thresholds.json"
            path.write_text(json.dumps(thresholds), encoding="utf-8")
            with self.assertRaisesRegex(paired.PairedEvalError, "min_non_target_samples"):
                paired.load_paired_thresholds(path)

    def test_sec10_excludes_the_log_message_control(self):
        known_rules = set(paired.canonical_rule_inventory(paired.DEFAULT_RULES_DIR))
        samples = paired.load_non_target_dataset(
            paired.DEFAULT_NON_TARGET_DATASET, known_rules
        )
        selected_ids = {
            sample["id"] for sample in paired.select_non_target_samples(samples, "SEC-10")
        }
        self.assertNotIn("non-target-19", selected_ids)

    def test_unknown_commit_fails_before_client_creation(self):
        anthropic_factory = Mock()
        anthropic_module = types.SimpleNamespace(Anthropic=anthropic_factory)
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.dict(sys.modules, {"anthropic": anthropic_module}),
            patch.object(execution, "current_commit", return_value="unknown"),
        ):
            with self.assertRaisesRegex(execution.PairedExecutionError, "commit"):
                execution.execute_real_run(
                    producer_model="producer",
                    judge_model="judge",
                    candidate="U-01",
                    with_rules="with",
                    without_rules="without",
                    target_samples=[],
                    non_target_samples=[],
                    identities={},
                    thresholds={
                        "min_target_samples": 5,
                        "min_non_target_samples": 30,
                        "min_target_delta": 0.0,
                        "max_non_target_drop": 0.0,
                        "max_skip_rate": 0.1,
                        "max_skip_delta": 0.05,
                        "max_cross_refs": 4,
                        "calibrated": True,
                    },
                    removal_evidence={},
                    cross_refs_exceeded=False,
                    artifact_root=Path(tmp),
                )
        anthropic_factory.assert_not_called()


unittest.main()
PY

dry_run_out="$(
  cd "${REPO_DIR}"
  env -u ANTHROPIC_API_KEY python3 eval/run_paired_eval.py \
    --candidate U-32 \
    --placebo-candidate SEC-18 \
    --dry-run \
    --artifact-root "${TMP_DIR}/runs"
)"

grep -qF "Paired runs: target-with, target-without, non-target-with, non-target-without" <<<"${dry_run_out}"
grep -qF "Removal assertions: file_set=pass, presence=pass, definition_site=pass, file_diff=pass, definition_count=pass" <<<"${dry_run_out}"
grep -qF "Cross references (13):" <<<"${dry_run_out}"
grep -qF "Empty-shell rule files:" <<<"${dry_run_out}"
grep -qF "Target samples: 0" <<<"${dry_run_out}"
grep -qF "Non-target samples: 32" <<<"${dry_run_out}"
grep -qF "Producer model:" <<<"${dry_run_out}"
grep -qF "Judge model: not required for dry-run" <<<"${dry_run_out}"
grep -qF "Judge prompt digest:" <<<"${dry_run_out}"
grep -qF "Rule text characters: with=" <<<"${dry_run_out}"
grep -qF "Placebo candidate: SEC-18" <<<"${dry_run_out}"
grep -qF "Verdict: not produced in dry-run" <<<"${dry_run_out}"
test ! -e "${TMP_DIR}/runs"

set +e
placebo_out="$(
  cd "${REPO_DIR}"
  env -u ANTHROPIC_API_KEY python3 eval/run_paired_eval.py \
    --candidate U-21 \
    --placebo-candidate U-16 \
    --dry-run \
    --artifact-root "${TMP_DIR}/placebo-runs" 2>&1
)"
placebo_rc=$?
set -e
test "${placebo_rc}" -ne 0
grep -qF "placebo length ratio" <<<"${placebo_out}"
test ! -e "${TMP_DIR}/placebo-runs"

set +e
placebo_cross_refs_out="$(
  cd "${REPO_DIR}"
  env -u ANTHROPIC_API_KEY python3 eval/run_paired_eval.py \
    --candidate SEC-12 \
    --placebo-candidate U-32 \
    --dry-run \
    --artifact-root "${TMP_DIR}/placebo-cross-ref-runs" 2>&1
)"
placebo_cross_refs_rc=$?
set -e
test "${placebo_cross_refs_rc}" -ne 0
grep -qF "placebo cross references exceed max_cross_refs" <<<"${placebo_cross_refs_out}"
test ! -e "${TMP_DIR}/placebo-cross-ref-runs"

set +e
compact_placebo_out="$(
  cd "${REPO_DIR}"
  env -u ANTHROPIC_API_KEY python3 eval/run_paired_eval.py \
    --candidate RS-10 \
    --placebo-candidate SEC-02 \
    --dry-run \
    --artifact-root "${TMP_DIR}/compact-placebo-runs" 2>&1
)"
compact_placebo_rc=$?
set -e
test "${compact_placebo_rc}" -ne 0
grep -qF "anonymous compact L7" <<<"${compact_placebo_out}"
test ! -e "${TMP_DIR}/compact-placebo-runs"

set +e
compact_out="$(
  cd "${REPO_DIR}"
  env -u ANTHROPIC_API_KEY python3 eval/run_paired_eval.py \
    --candidate U-04 \
    --dry-run \
    --artifact-root "${TMP_DIR}/compact-runs" 2>&1
)"
compact_rc=$?
set -e
test "${compact_rc}" -ne 0
grep -qF "anonymous compact L5" <<<"${compact_out}"
test ! -e "${TMP_DIR}/compact-runs"

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
