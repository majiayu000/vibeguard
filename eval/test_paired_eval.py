#!/usr/bin/env python3
"""Deterministic tests for the paired with/without rule evaluation gate."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paired_execution as execution  # noqa: E402
import run_paired_eval as paired  # noqa: E402
from dataset import DatasetError, load_dataset  # noqa: E402


def sequence_client(replies: list[str]) -> Mock:
    client = Mock()
    client.messages.create.side_effect = [
        type("Response", (), {"content": [type("Block", (), {"text": reply})()]})()
        for reply in replies
    ]
    return client


class RemovalFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.real = self.root / "real"
        self.real.mkdir()
        (self.real / "rules.md").write_bytes(
            b"# Rules\r\n\r\n"
            b"## U-01: candidate\r\n\r\ncandidate body\r\n\r\n"
            b"## U-02: neighbor\r\n\r\nneighbor body\r\n"
        )
        (self.real / "other.md").write_bytes(
            b"## W-01: other\n\nSee U-01 for related guidance.\n"
        )
        self.core = self.root / "core.md"
        self.core.write_bytes(
            b"| ID | Rule |\n"
            b"| --- | --- |\n"
            b"| U-01 | candidate core |\n"
            b"| W-01 | other core |\n"
        )
        self.section = paired.extract_candidate_section(
            (self.real / "rules.md").read_bytes(), "U-01"
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def copy_pair(self) -> tuple[Path, Path]:
        mutated = self.root / f"mutated-{len(list(self.root.glob('mutated-*')))}"
        shutil.copytree(self.real, mutated)
        core = self.root / f"core-{mutated.name}.md"
        shutil.copy2(self.core, core)
        return mutated, core

    def audit(self, mutated: Path, core: Path, removed: bytes | None = None) -> set[str]:
        evidence = paired.audit_removal(
            self.real,
            mutated,
            self.core,
            core,
            "U-01",
            expected_rule_file=Path("rules.md"),
            expected_removed_section=removed or self.section,
        )
        return set(evidence["failed_assertions"])

    def test_valid_dual_source_removal_preserves_bytes(self) -> None:
        mutated, core = self.copy_pair()
        source = (mutated / "rules.md").read_bytes()
        stripped, removed = paired.strip_candidate_section(source, "U-01")
        (mutated / "rules.md").write_bytes(stripped)
        core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])

        evidence = paired.audit_removal(
            self.real,
            mutated,
            self.core,
            core,
            "U-01",
            expected_rule_file=Path("rules.md"),
            expected_removed_section=removed,
        )

        self.assertEqual(evidence["failed_assertions"], [])
        self.assertEqual(evidence["assertions"], {
            "file_set": "pass",
            "presence": "pass",
            "definition_site": "pass",
            "file_diff": "pass",
            "definition_count": "pass",
        })
        self.assertEqual(evidence["cross_references"], ["other.md:3"])

    def test_mutations_are_caught_by_independent_named_assertions(self) -> None:
        cases: list[tuple[str, str, callable]] = []

        def no_op(tree: Path, core: Path) -> bytes:
            return self.section

        cases.append(("no-op", "definition_site", no_op))

        def greedy_next(tree: Path, core: Path) -> bytes:
            source = (tree / "rules.md").read_bytes()
            start = source.index(b"## U-01:")
            removed = source[start:]
            (tree / "rules.md").write_bytes(source[:start])
            core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])
            return removed

        cases.append(("greedy-to-eof", "definition_count", greedy_next))

        def whole_file(tree: Path, core: Path) -> bytes:
            (tree / "rules.md").write_bytes(b"")
            core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])
            return self.section

        cases.append(("whole-file", "file_diff", whole_file))

        def only_core(tree: Path, core: Path) -> bytes:
            core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])
            return self.section

        cases.append(("only-core", "definition_site", only_core))

        def only_section(tree: Path, core: Path) -> bytes:
            stripped, removed = paired.strip_candidate_section(
                (tree / "rules.md").read_bytes(), "U-01"
            )
            (tree / "rules.md").write_bytes(stripped)
            return removed

        cases.append(("only-section", "definition_site", only_section))

        def title_only(tree: Path, core: Path) -> bytes:
            source = (tree / "rules.md").read_bytes()
            (tree / "rules.md").write_bytes(source.replace(b"## U-01: candidate\r\n", b"", 1))
            core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])
            return self.section

        cases.append(("title-only", "file_diff", title_only))

        def body_only(tree: Path, core: Path) -> bytes:
            source = (tree / "rules.md").read_bytes()
            (tree / "rules.md").write_bytes(source.replace(b"candidate body\r\n\r\n", b"", 1))
            core.write_bytes(paired.strip_core_row(core.read_bytes(), "U-01")[0])
            return self.section

        cases.append(("body-only", "definition_site", body_only))

        for name, expected, mutate in cases:
            with self.subTest(name=name):
                tree, core = self.copy_pair()
                removed = mutate(tree, core)
                self.assertIn(expected, self.audit(tree, core, removed))

    def test_file_set_and_byte_drift_mutations_are_rejected(self) -> None:
        missing, missing_core = self.copy_pair()
        (missing / "other.md").unlink()
        self.assertIn("file_set", self.audit(missing, missing_core))

        extra, extra_core = self.copy_pair()
        (extra / "extra.md").write_text("extra", encoding="utf-8")
        self.assertIn("file_set", self.audit(extra, extra_core))

        drift, drift_core = self.copy_pair()
        stripped, removed = paired.strip_candidate_section(
            (drift / "rules.md").read_bytes(), "U-01"
        )
        (drift / "rules.md").write_bytes(stripped)
        drift_core.write_bytes(paired.strip_core_row(drift_core.read_bytes(), "U-01")[0])
        (drift / "other.md").write_bytes(
            (drift / "other.md").read_bytes().replace(b"\n", b"\r\n")
        )
        self.assertIn("file_diff", self.audit(drift, drift_core, removed))


class RepositoryRemovalTest(unittest.TestCase):
    def test_canonical_inventory_and_all_rule_smoke(self) -> None:
        inventory = paired.canonical_rule_inventory(paired.DEFAULT_RULES_DIR)
        self.assertEqual(len(inventory), 127)
        self.assertEqual(len(set(inventory)), 127)
        self.assertTrue(
            {"TASTE-ANSI", "TASTE-ASYNC-UNWRAP", "TASTE-PANIC-MSG"}.issubset(inventory)
        )

        with tempfile.TemporaryDirectory() as tmp:
            empty_shells = set()
            cross_ref_rules = set()
            for rule_id in inventory:
                evidence = paired.prepare_without_rules(
                    paired.DEFAULT_RULES_DIR,
                    paired.DEFAULT_CORE_RULES_FILE,
                    rule_id,
                    Path(tmp) / rule_id,
                )
                self.assertEqual(evidence["failed_assertions"], [], rule_id)
                if evidence["empty_shells"]:
                    empty_shells.add(rule_id)
                if evidence["cross_references"]:
                    cross_ref_rules.add(rule_id)

        self.assertEqual(len(empty_shells), 10)
        self.assertEqual(len(cross_ref_rules), 30)

    def test_u32_cross_reference_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            evidence = paired.prepare_without_rules(
                paired.DEFAULT_RULES_DIR,
                paired.DEFAULT_CORE_RULES_FILE,
                "U-32",
                Path(tmp) / "candidate",
            )

        self.assertEqual(len(evidence["cross_references"]), 13)
        self.assertTrue(paired.cross_reference_limit_exceeded(evidence, 4))
        fixture = {"cross_references": [f"fixture.md:{line}" for line in range(1, 5)]}
        self.assertFalse(paired.cross_reference_limit_exceeded(fixture, 4))
        fixture["cross_references"].append("fixture.md:5")
        self.assertTrue(paired.cross_reference_limit_exceeded(fixture, 4))

    def test_w11_literal_markdown_headings_are_removed_with_the_rule(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            evidence = paired.prepare_without_rules(
                paired.DEFAULT_RULES_DIR,
                paired.DEFAULT_CORE_RULES_FILE,
                "W-11",
                Path(tmp) / "candidate",
            )
            without = (
                evidence["rules_dir"] / "common" / "fact-inference-separation.md"
            ).read_text(encoding="utf-8")

        self.assertNotIn("## Facts", without)
        self.assertNotIn("## Inferences", without)
        self.assertEqual(evidence["failed_assertions"], [])


class DatasetAndIdentityTest(unittest.TestCase):
    def test_target_partition_is_exact_and_non_target_schema_is_independent(self) -> None:
        target = paired.select_target_samples(load_dataset(paired.DEFAULT_TARGET_DATASET), "SEC-01")
        self.assertEqual({sample["rule"] for sample in target}, {"SEC-01"})
        self.assertNotIn("NONE", {sample["rule"] for sample in target})

        known_rules = set(paired.canonical_rule_inventory(paired.DEFAULT_RULES_DIR))
        non_target = paired.load_non_target_dataset(
            paired.DEFAULT_NON_TARGET_DATASET, known_rules
        )
        self.assertGreaterEqual(len(non_target), 30)
        self.assertTrue(all({"id", "task", "input", "rubric"} <= sample.keys() for sample in non_target))
        self.assertTrue(all("rule" not in sample and "type" not in sample for sample in non_target))
        self.assertTrue(all("excluded_rules" in sample for sample in non_target))

        u15_samples = paired.select_non_target_samples(non_target, "U-15")
        self.assertNotIn("non-target-23", {sample["id"] for sample in u15_samples})
        self.assertGreaterEqual(len(u15_samples), 30)
        u21_samples = paired.select_non_target_samples(non_target, "U-21")
        self.assertNotIn("non-target-08", {sample["id"] for sample in u21_samples})
        self.assertGreaterEqual(len(u21_samples), 30)

    def test_non_target_dataset_rejects_unknown_excluded_rule_ids(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "non-target.jsonl"
            path.write_text(
                json.dumps({
                    "id": "n1",
                    "task": "Answer",
                    "input": "x",
                    "rubric": "Be correct",
                    "excluded_rules": ["U-211"],
                })
                + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(DatasetError, "unknown excluded rule"):
                paired.load_non_target_dataset(path, {"U-21"})

    def test_paired_identity_rejects_any_non_rule_drift(self) -> None:
        base = {
            "model": "producer",
            "dataset_digest": "dataset",
            "sample_set_digest": "samples",
            "rule_digest": "with",
        }
        without = {**base, "rule_digest": "without"}
        paired.assert_paired_identity(base, without)
        for field in ("model", "dataset_digest", "sample_set_digest"):
            changed = {**without, field: "changed"}
            with self.subTest(field=field), self.assertRaisesRegex(
                paired.PairedEvalError, field
            ):
                paired.assert_paired_identity(base, changed)
        with self.assertRaisesRegex(paired.PairedEvalError, "rule_digest"):
            paired.assert_paired_identity(base, {**without, "rule_digest": "with"})

    def test_thresholds_reject_non_finite_and_out_of_domain_values(self) -> None:
        base = {
            "min_target_samples": 5,
            "min_non_target_samples": 30,
            "min_target_delta": 0.0,
            "max_non_target_drop": 0.0,
            "max_skip_rate": 0.1,
            "max_skip_delta": 0.05,
            "max_cross_refs": 4,
            "max_placebo_length_ratio": 0.25,
            "calibrated": False,
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "thresholds.json"
            for key, value in (
                ("max_skip_rate", float("nan")),
                ("max_skip_delta", 1.1),
                ("min_target_samples", 1.5),
            ):
                with self.subTest(key=key, value=value):
                    path.write_text(
                        json.dumps({**base, key: value}), encoding="utf-8"
                    )
                    with self.assertRaisesRegex(paired.PairedEvalError, key):
                        paired.load_paired_thresholds(path)

    def test_placebo_must_be_distinct_and_similar_length(self) -> None:
        with self.assertRaisesRegex(paired.PairedEvalError, "must differ"):
            paired.validate_placebo_candidate("U-32", "U-32", 4000, 4000, 0.25)
        with self.assertRaisesRegex(paired.PairedEvalError, "length ratio"):
            paired.validate_placebo_candidate("U-32", "U-31", 4000, 700, 0.25)
        with self.assertRaisesRegex(paired.PairedEvalError, "length ratio"):
            paired.validate_placebo_candidate("U-21", "U-16", 240, 406, 0.25)
        paired.validate_placebo_candidate("U-32", "SEC-12", 4000, 4100, 0.25)

    def test_candidates_duplicated_by_anonymous_compact_rules_are_rejected(self) -> None:
        for candidate in ("U-04", "U-17", "U-23", "U-24", "U-29", "SEC-02"):
            with self.subTest(candidate=candidate), self.assertRaisesRegex(
                paired.PairedEvalError, "anonymous compact"
            ):
                paired.validate_candidate_supported(candidate)
        paired.validate_candidate_supported("U-32")


class JudgeAndVerdictTest(unittest.TestCase):
    def setUp(self) -> None:
        self.thresholds = {
            "min_target_samples": 5,
            "min_non_target_samples": 30,
            "min_target_delta": 0.0,
            "max_non_target_drop": 0.0,
            "max_skip_rate": 0.1,
            "max_skip_delta": 0.05,
            "max_cross_refs": 4,
            "calibrated": True,
        }

    def test_pairwise_parser_and_swapped_mapping_are_strict(self) -> None:
        verdict = paired.parse_pairwise_judge('{"winner":"A","reason":"clearer"}')
        self.assertEqual(verdict["winner"], "A")
        for bad in (
            '{"winner":"with","reason":"leaks label"}',
            '{"winner":"A"}',
            "A",
        ):
            with self.subTest(bad=bad), self.assertRaises(paired.PairwiseJudgeError):
                paired.parse_pairwise_judge(bad)

        result = paired.judge_pair(
            sequence_client([
                '{"winner":"A","reason":"better"}',
                '{"winner":"B","reason":"better"}',
            ]),
            "judge-model",
            {"id": "n1", "task": "answer", "input": "x", "rubric": "correct"},
            "with output",
            "without output",
        )
        self.assertEqual(result["outcome"], "with_win")
        self.assertEqual(result["mapped_outcomes"], ["with_win", "with_win"])
        self.assertEqual(len(result["raw_judge_responses"]), 2)

    def test_swapped_conflict_makes_non_target_inconclusive(self) -> None:
        result = paired.judge_pair(
            sequence_client([
                '{"winner":"A","reason":"first"}',
                '{"winner":"A","reason":"position"}',
            ]),
            "judge-model",
            {"id": "n1", "task": "answer", "input": "x", "rubric": "correct"},
            "with output",
            "without output",
        )
        self.assertEqual(result["outcome"], "conflict")

        axis = paired.compute_non_target_axis([result] * 30, 30, self.thresholds)
        self.assertEqual(axis["verdict"], "inconclusive")
        self.assertIn("judge conflict", " ".join(axis["reasons"]))

    def test_judge_interrupt_preserves_the_completed_paid_response(self) -> None:
        client = Mock()
        client.messages.create.side_effect = [
            type(
                "Response",
                (),
                {
                    "content": [
                        type(
                            "Block",
                            (),
                            {"text": '{"winner":"A","reason":"better"}'},
                        )()
                    ]
                },
            )(),
            KeyboardInterrupt(),
        ]

        result = paired.judge_pair(
            client,
            "judge-model",
            {"id": "n1", "task": "answer", "input": "x", "rubric": "correct"},
            "with output",
            "without output",
        )

        self.assertTrue(result["interrupted"])
        self.assertTrue(result["skipped"])
        self.assertEqual(len(result["raw_judge_responses"]), 1)
        self.assertEqual(result["mapped_outcomes"], ["with_win"])
        self.assertEqual(client.messages.create.call_count, 2)

    def test_requested_sample_count_remains_the_denominator(self) -> None:
        with_results = [{"detected": True}] * 4 + [{"skipped": True}]
        without_results = [{"detected": False}] * 5
        axis = paired.compute_target_axis(with_results, without_results, 5, self.thresholds)

        self.assertEqual(axis["with_pass_rate"], 0.8)
        self.assertEqual(axis["without_pass_rate"], 0.0)
        self.assertEqual(axis["with_skip_rate"], 0.2)
        self.assertEqual(axis["verdict"], "inconclusive")

    def test_overall_is_conjunctive_and_uncalibrated_never_passes(self) -> None:
        self.assertEqual(
            paired.compute_overall_verdict(
                {"verdict": "pass"}, {"verdict": "fail"}, self.thresholds, False
            )["verdict"],
            "fail",
        )
        self.assertEqual(
            paired.compute_overall_verdict(
                {"verdict": "pass"}, {"verdict": "pass"}, self.thresholds, False
            )["verdict"],
            "pass",
        )
        uncalibrated = {**self.thresholds, "calibrated": False}
        result = paired.compute_overall_verdict(
            {"verdict": "pass"}, {"verdict": "pass"}, uncalibrated, False
        )
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertNotEqual(paired.real_run_exit_code(result["verdict"]), 0)


class RealExecutionTest(unittest.TestCase):
    def test_non_target_producer_uses_an_ordinary_task_contract(self) -> None:
        client = sequence_client(["plain answer"])
        sample = {
            "id": "n1",
            "task": "Explain a value",
            "input": "42",
            "rubric": "Be correct",
        }

        result = execution.evaluate_non_target_sample(
            client,
            "producer-model",
            execution.build_non_target_system_prompt("loaded rules"),
            sample,
        )

        self.assertEqual(result["response"], "plain answer")
        request = client.messages.create.call_args.kwargs
        self.assertIn("ordinary task", request["system"])
        self.assertNotIn('"detected"', request["system"])
        self.assertEqual(request["messages"][0]["content"], "Task: Explain a value\n\nInput:\n42")

    def test_non_target_producer_treats_empty_reply_as_skipped(self) -> None:
        result = execution.evaluate_non_target_sample(
            sequence_client(["   "]),
            "producer-model",
            execution.build_non_target_system_prompt("loaded rules"),
            {
                "id": "n1",
                "task": "Answer",
                "input": "x",
                "rubric": "Be correct",
            },
        )

        self.assertTrue(result["skipped"])
        self.assertIn("empty", result["error"])

    def test_real_uncalibrated_run_writes_auditable_report_and_fails_closed(self) -> None:
        target_samples = [
            {
                "id": f"target-{index}",
                "rule": "U-01",
                "severity": "high",
                "lang": "python",
                "input": "print('x')",
                "code": "print('x')",
                "description": "target",
                "expected_action": "warn_or_refuse",
            }
            for index in range(5)
        ]
        non_target_samples = [
            {
                "id": f"non-target-{index}",
                "task": "Answer",
                "input": str(index),
                "rubric": "Be correct",
            }
            for index in range(30)
        ]
        target_with = json.dumps({
            "detected": True,
            "rule_ids": ["U-01"],
            "confidence": "high",
            "reason": "caught",
        })
        target_without = json.dumps({
            "detected": False,
            "rule_ids": [],
            "confidence": "high",
            "reason": "not caught",
        })
        replies = (
            [target_with] * 5
            + [target_without] * 5
            + [f"with response {index}" for index in range(30)]
            + [f"without response {index}" for index in range(30)]
            + [
                json.dumps({"winner": "tie", "reason": "equivalent"})
                for _ in range(60)
            ]
        )
        client = sequence_client(replies)
        anthropic_module = types.SimpleNamespace(Anthropic=lambda: client)
        thresholds = {
            "min_target_samples": 5,
            "min_non_target_samples": 30,
            "min_target_delta": 0.0,
            "max_non_target_drop": 0.0,
            "max_skip_rate": 0.1,
            "max_skip_delta": 0.05,
            "max_cross_refs": 4,
            "calibrated": False,
        }
        identity_base = {
            "model": "producer-model",
            "dataset_digest": "dataset",
            "sample_set_digest": "samples",
        }
        evidence = {
            "candidate_file": "common/example.md",
            "assertions": {
                "file_set": "pass",
                "presence": "pass",
                "definition_site": "pass",
                "file_diff": "pass",
                "definition_count": "pass",
            },
            "failed_assertions": [],
            "cross_references": [],
            "empty_shells": [],
            "definition_count_with": 127,
            "definition_count_without": 126,
            "removed_section_characters": 100,
        }

        with tempfile.TemporaryDirectory() as tmp, patch.dict(
            sys.modules, {"anthropic": anthropic_module}
        ):
            exit_code = execution.execute_real_run(
                producer_model="producer-model",
                judge_model="judge-model",
                candidate="U-01",
                with_rules="rules with candidate",
                without_rules="rules without candidate",
                target_samples=target_samples,
                non_target_samples=non_target_samples,
                identities={
                    "target_with": {**identity_base, "rule_digest": "with"},
                    "target_without": {**identity_base, "rule_digest": "without"},
                    "non_target_with": {**identity_base, "rule_digest": "with"},
                    "non_target_without": {**identity_base, "rule_digest": "without"},
                },
                thresholds=thresholds,
                removal_evidence=evidence,
                cross_refs_exceeded=False,
                artifact_root=Path(tmp),
            )
            reports = list(Path(tmp).glob("*/report.json"))
            self.assertEqual(len(reports), 1)
            report = json.loads(reports[0].read_text(encoding="utf-8"))

        self.assertEqual(exit_code, 1)
        self.assertEqual(report["overall"]["verdict"], "inconclusive")
        self.assertEqual(report["target_axis"]["target_delta"], 1.0)
        self.assertEqual(report["non_target_axis"]["quality_delta"], 0.0)
        self.assertEqual(report["producer_model"], "producer-model")
        self.assertEqual(report["judge_model"], "judge-model")
        self.assertEqual(len(report["judge_prompt_digest"]), 64)
        self.assertEqual(
            report["non_target_results"]["judge"][0]["mapped_outcomes"],
            ["tie", "tie"],
        )

    def test_keyboard_interrupt_writes_partial_report_and_stops_new_calls(self) -> None:
        target_samples = [
            {
                "id": f"target-{index}",
                "rule": "U-01",
                "severity": "high",
                "lang": "python",
                "input": "print('x')",
                "code": "print('x')",
                "description": "target",
                "expected_action": "warn_or_refuse",
            }
            for index in range(5)
        ]
        non_target_samples = [
            {
                "id": f"non-target-{index}",
                "task": "Answer",
                "input": str(index),
                "rubric": "Be correct",
            }
            for index in range(30)
        ]
        target_reply = json.dumps({
            "detected": True,
            "rule_ids": ["U-01"],
            "confidence": "high",
            "reason": "caught",
        })
        client = Mock()
        client.messages.create.side_effect = (
            [
                type(
                    "Response",
                    (),
                    {"content": [type("Block", (), {"text": target_reply})()]},
                )()
                for _ in range(10)
            ]
            + [
                type(
                    "Response",
                    (),
                    {"content": [type("Block", (), {"text": "paid partial"})()]},
                )(),
                KeyboardInterrupt(),
            ]
        )
        anthropic_module = types.SimpleNamespace(Anthropic=lambda: client)
        thresholds = {
            "min_target_samples": 5,
            "min_non_target_samples": 30,
            "min_target_delta": 0.0,
            "max_non_target_drop": 0.0,
            "max_skip_rate": 0.1,
            "max_skip_delta": 0.05,
            "max_cross_refs": 4,
            "calibrated": True,
        }
        identity_base = {
            "model": "producer-model",
            "dataset_digest": "dataset",
            "sample_set_digest": "samples",
        }
        evidence = {
            "candidate_file": "common/example.md",
            "assertions": {
                "file_set": "pass",
                "presence": "pass",
                "definition_site": "pass",
                "file_diff": "pass",
                "definition_count": "pass",
            },
            "failed_assertions": [],
            "cross_references": [],
            "empty_shells": [],
            "definition_count_with": 127,
            "definition_count_without": 126,
            "removed_section_characters": 100,
        }

        with tempfile.TemporaryDirectory() as tmp, patch.dict(
            sys.modules, {"anthropic": anthropic_module}
        ):
            exit_code = execution.execute_real_run(
                producer_model="producer-model",
                judge_model="judge-model",
                candidate="U-01",
                with_rules="rules with candidate",
                without_rules="rules without candidate",
                target_samples=target_samples,
                non_target_samples=non_target_samples,
                identities={
                    "target_with": {**identity_base, "rule_digest": "with"},
                    "target_without": {**identity_base, "rule_digest": "without"},
                    "non_target_with": {**identity_base, "rule_digest": "with"},
                    "non_target_without": {**identity_base, "rule_digest": "without"},
                },
                thresholds=thresholds,
                removal_evidence=evidence,
                cross_refs_exceeded=False,
                artifact_root=Path(tmp),
            )
            report_path = next(Path(tmp).glob("*/report.json"))
            report = json.loads(report_path.read_text(encoding="utf-8"))

        self.assertEqual(exit_code, 1)
        self.assertTrue(report["interrupted"])
        self.assertEqual(report["interruption_stage"], "non_target_with")
        self.assertEqual(report["overall"]["verdict"], "inconclusive")
        self.assertEqual(report["non_target_results"]["with"][0]["response"], "paid partial")
        self.assertTrue(report["non_target_results"]["with"][1]["skipped"])
        self.assertTrue(all(
            result["skipped"] for result in report["non_target_results"]["without"]
        ))
        self.assertEqual(client.messages.create.call_count, 12)


if __name__ == "__main__":
    unittest.main()
