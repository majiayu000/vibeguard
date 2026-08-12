#!/usr/bin/env python3
"""Paired with/without evaluation for one prompt-injected VibeGuard rule."""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]

from dataset import (
    DatasetError,
    DuplicateJsonKeyError,
    file_digest,
    load_dataset,
    reject_duplicate_json_keys,
    sample_set_digest,
    sha256_text,
)
from model_baseline import ModelBaselineError, load_model_baseline
from paired_execution import PairedExecutionError, execute_real_run
from paired_provenance import (
    PairedProvenanceError,
    absolute_without_leaf_resolution,
    evaluated_provenance_paths as _evaluated_provenance_paths,
    pin_evaluated_inputs,
)
from paired_scoring import (
    PairwiseJudgeError,
    build_judge_prompt,
    compute_non_target_axis,
    compute_overall_verdict,
    compute_target_axis,
    judge_pair,
    parse_pairwise_judge,
    real_run_exit_code,
)
from run_eval import (
    DEFAULT_CORE_RULES_FILE,
    DEFAULT_RULES_DIR,
    load_rules,
)

LIB_DIR = REPO_ROOT / "scripts" / "lib"
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

from vibeguard_manifest import RULE_ID_HEADING_RE, RULE_ID_TABLE_RE  # noqa: E402

DEFAULT_TARGET_DATASET = REPO_ROOT / "eval" / "datasets" / "v1.jsonl"
DEFAULT_NON_TARGET_DATASET = REPO_ROOT / "eval" / "paired" / "non_target_v1.jsonl"
DEFAULT_THRESHOLDS = REPO_ROOT / "eval" / "paired" / "thresholds.json"
DEFAULT_ARTIFACT_ROOT = REPO_ROOT / "eval" / "paired" / "runs"
NON_TARGET_STRING_FIELDS = {"id", "task", "input", "rubric"}
NON_TARGET_FIELDS = NON_TARGET_STRING_FIELDS | {"excluded_rules"}
RULE_ID_TOKEN_RE = re.compile(
    r"^(?:RS|GO|TS|PY|U|SEC|W|TASTE)-[A-Za-z0-9-]+$"
)
THRESHOLD_KEYS = {
    "min_target_samples",
    "min_non_target_samples",
    "min_target_delta",
    "max_non_target_drop",
    "max_skip_rate",
    "max_skip_delta",
    "max_cross_refs",
    "max_placebo_length_ratio",
    "calibrated",
}
SHARED_CORE_RULE_EQUIVALENTS = {
    "SEC-02": "Key detailed rules (SEC-02)",
    "U-04": "Core contract (Scope)",
    "U-17": "Key detailed rules (U-17)",
    "U-29": "Key detailed rules (U-29)",
}
APPROVED_PLACEBO_PAIRS = {
    frozenset(("SEC-12", "U-32")): (
        "MCP tool-description drift is unrelated to prompt rule-overload limits"
    ),
    frozenset(("SEC-18", "U-32")): (
        "external-agent input scoring is unrelated to prompt rule-overload limits"
    ),
}


class PairedEvalError(ValueError):
    """Raised when paired-eval inputs or invariants are invalid."""


def _decode(content: bytes, label: str) -> str:
    try:
        return content.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PairedEvalError(f"{label} is not valid UTF-8: {exc}") from exc


def _rule_matches(content: bytes, label: str) -> list[re.Match[str]]:
    return list(RULE_ID_HEADING_RE.finditer(_decode(content, label)))


def extract_candidate_section(content: bytes, candidate: str) -> bytes:
    """Return exactly one candidate section without normalizing its bytes."""
    text = _decode(content, "rule file")
    matches = [
        match for match in RULE_ID_HEADING_RE.finditer(text)
        if match.group(1).upper() == candidate.upper()
    ]
    if len(matches) != 1:
        raise PairedEvalError(
            f"candidate rule {candidate} must have exactly one definition in its file; "
            f"found {len(matches)}"
        )
    start = matches[0].start()
    next_heading = RULE_ID_HEADING_RE.search(text, matches[0].end())
    end = next_heading.start() if next_heading else len(text)
    return text[start:end].encode("utf-8")


def strip_candidate_section(content: bytes, candidate: str) -> tuple[bytes, bytes]:
    section = extract_candidate_section(content, candidate)
    start = content.find(section)
    if start < 0 or content.find(section, start + 1) >= 0:
        raise PairedEvalError(f"candidate section for {candidate} is not uniquely removable")
    return content[:start] + content[start + len(section):], section


def strip_core_row(content: bytes, candidate: str) -> tuple[bytes, bytes]:
    """Remove an optional candidate table row from the compact core source."""
    text = _decode(content, "core rule file")
    kept: list[str] = []
    removed: list[str] = []
    for line in text.splitlines(keepends=True):
        match = RULE_ID_TABLE_RE.match(line)
        if match and match.group(1).upper() == candidate.upper():
            removed.append(line)
        else:
            kept.append(line)
    if len(removed) > 1:
        raise PairedEvalError(f"core rule file has duplicate rows for {candidate}")
    return "".join(kept).encode("utf-8"), "".join(removed).encode("utf-8")


def canonical_rule_inventory(rules_dir: Path) -> list[str]:
    rule_ids: list[str] = []
    for path in sorted(rules_dir.rglob("*.md")):
        rule_ids.extend(
            match.group(1)
            for match in _rule_matches(path.read_bytes(), str(path))
        )
    return sorted(rule_ids)


def _relative_files(root: Path) -> set[Path]:
    return {path.relative_to(root) for path in root.rglob("*") if path.is_file()}


def _candidate_locations(rules_dir: Path, candidate: str) -> list[Path]:
    locations: list[Path] = []
    for path in sorted(rules_dir.rglob("*.md")):
        ids = [match.group(1).upper() for match in _rule_matches(path.read_bytes(), str(path))]
        locations.extend([path.relative_to(rules_dir)] * ids.count(candidate.upper()))
    return locations


def _count_definitions(rules_dir: Path) -> int:
    return sum(
        len(_rule_matches(path.read_bytes(), str(path)))
        for path in rules_dir.rglob("*.md")
    )


def _core_candidate_rows(content: bytes, candidate: str) -> int:
    return sum(
        1
        for match in RULE_ID_TABLE_RE.finditer(_decode(content, "core rule file"))
        if match.group(1).upper() == candidate.upper()
    )


def find_cross_references(
    rules_dir: Path,
    candidate: str,
    core_file: Path | None = None,
) -> list[str]:
    token = re.compile(
        rf"(?<![A-Za-z0-9-]){re.escape(candidate)}(?![A-Za-z0-9-])",
        re.IGNORECASE,
    )
    references: list[str] = []
    for path in sorted(rules_dir.rglob("*.md")):
        relative = path.relative_to(rules_dir).as_posix()
        content = path.read_bytes()
        text = _decode(content, str(path))
        excluded_lines: set[int] = set()
        matches = [
            match for match in RULE_ID_HEADING_RE.finditer(text)
            if match.group(1).upper() == candidate.upper()
        ]
        if matches:
            section = _decode(
                extract_candidate_section(content, candidate), "candidate section"
            )
            start = text.index(section)
            first_line = text.count("\n", 0, start) + 1
            excluded_lines.update(
                range(first_line, first_line + section.count("\n") + 1)
            )
        for line_number, line in enumerate(text.splitlines(), start=1):
            if line_number in excluded_lines:
                continue
            if token.search(line):
                references.append(f"{relative}:{line_number}")
    if core_file is not None:
        core_text = _decode(core_file.read_bytes(), str(core_file))
        for line_number, line in enumerate(core_text.splitlines(), start=1):
            match = RULE_ID_TABLE_RE.match(line)
            if match and match.group(1).upper() == candidate.upper():
                continue
            if token.search(line):
                references.append(f"{core_file.name}:{line_number}")
    return references


def _empty_rule_files(rules_dir: Path) -> list[str]:
    return [
        path.relative_to(rules_dir).as_posix()
        for path in sorted(rules_dir.rglob("*.md"))
        if not _rule_matches(path.read_bytes(), str(path))
    ]


def audit_removal(
    real_rules_dir: Path,
    without_rules_dir: Path,
    real_core_file: Path,
    without_core_file: Path,
    candidate: str,
    *,
    expected_rule_file: Path,
    expected_removed_section: bytes,
) -> dict[str, Any]:
    """Run every removal assertion and report all failures independently."""
    checks: dict[str, bool] = {}
    real_files = _relative_files(real_rules_dir)
    without_files = _relative_files(without_rules_dir)
    checks["file_set"] = real_files == without_files

    locations = _candidate_locations(real_rules_dir, candidate)
    checks["presence"] = locations == [expected_rule_file]

    without_locations = _candidate_locations(without_rules_dir, candidate)
    without_core = without_core_file.read_bytes()
    checks["definition_site"] = (
        not without_locations and _core_candidate_rows(without_core, candidate) == 0
    )

    file_diff_ok = checks["file_set"]
    if file_diff_ok:
        changed = [
            relative
            for relative in sorted(real_files)
            if (real_rules_dir / relative).read_bytes()
            != (without_rules_dir / relative).read_bytes()
        ]
        source = (real_rules_dir / expected_rule_file).read_bytes()
        start = source.find(expected_removed_section)
        expected_target = (
            source[:start] + source[start + len(expected_removed_section):]
            if start >= 0
            else b""
        )
        file_diff_ok = (
            changed == [expected_rule_file]
            and start >= 0
            and (without_rules_dir / expected_rule_file).read_bytes() == expected_target
        )
    expected_core, _ = strip_core_row(real_core_file.read_bytes(), candidate)
    checks["file_diff"] = file_diff_ok and without_core == expected_core

    definition_delta = (
        _count_definitions(real_rules_dir) - _count_definitions(without_rules_dir)
    )
    removed_text = _decode(expected_removed_section, "removed candidate section")
    first_line_end = removed_text.find("\n")
    remainder = removed_text[first_line_end + 1:] if first_line_end >= 0 else ""
    checks["definition_count"] = (
        definition_delta == 1 and RULE_ID_HEADING_RE.search(remainder) is None
    )

    failed = [name for name, passed in checks.items() if not passed]
    return {
        "assertions": {
            name: "pass" if passed else "fail" for name, passed in checks.items()
        },
        "failed_assertions": failed,
        "cross_references": find_cross_references(
            real_rules_dir, candidate, real_core_file
        ),
        "empty_shells": _empty_rule_files(without_rules_dir),
        "definition_count_with": _count_definitions(real_rules_dir),
        "definition_count_without": _count_definitions(without_rules_dir),
    }


def prepare_without_rules(
    rules_dir: Path,
    core_file: Path,
    candidate: str,
    destination: Path,
) -> dict[str, Any]:
    """Copy both rule sources, remove one candidate, and verify the result."""
    locations = _candidate_locations(rules_dir, candidate)
    if len(locations) != 1:
        raise PairedEvalError(
            f"candidate rule {candidate} must exist exactly once; found {len(locations)}"
        )
    if destination.exists():
        raise PairedEvalError(f"temporary destination already exists: {destination}")

    without_rules = destination / "rules"
    without_core = destination / "core.md"
    destination.mkdir(parents=True)
    shutil.copytree(rules_dir, without_rules)
    shutil.copy2(core_file, without_core)

    relative = locations[0]
    target = without_rules / relative
    stripped, removed = strip_candidate_section(target.read_bytes(), candidate)
    target.write_bytes(stripped)
    stripped_core, _ = strip_core_row(without_core.read_bytes(), candidate)
    without_core.write_bytes(stripped_core)

    evidence = audit_removal(
        rules_dir,
        without_rules,
        core_file,
        without_core,
        candidate,
        expected_rule_file=relative,
        expected_removed_section=removed,
    )
    if evidence["failed_assertions"]:
        raise PairedEvalError(
            "candidate removal assertion(s) failed: "
            + ", ".join(evidence["failed_assertions"])
        )
    evidence.update({
        "rules_dir": without_rules,
        "core_file": without_core,
        "candidate_file": relative.as_posix(),
        "removed_section_characters": len(_decode(removed, "candidate section")),
    })
    return evidence


def cross_reference_limit_exceeded(evidence: dict[str, Any], maximum: int) -> bool:
    return len(evidence["cross_references"]) > maximum


def load_non_target_dataset(
    path: Path, known_rule_ids: set[str]
) -> list[dict[str, str]]:
    if not path.exists():
        raise DatasetError(f"Non-target dataset not found: {path}")
    known_rules = {rule_id.upper() for rule_id in known_rule_ids}
    samples: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    with path.open(encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            if not raw.strip():
                continue
            try:
                sample = json.loads(
                    raw,
                    object_pairs_hook=reject_duplicate_json_keys,
                )
            except DuplicateJsonKeyError as exc:
                raise DatasetError(f"{path}:{line_number}: {exc}") from exc
            except json.JSONDecodeError as exc:
                raise DatasetError(
                    f"{path}:{line_number}: invalid JSON: {exc.msg}"
                ) from exc
            if not isinstance(sample, dict):
                raise DatasetError(f"{path}:{line_number}: sample must be an object")
            missing = sorted(NON_TARGET_FIELDS - sample.keys())
            if missing:
                raise DatasetError(
                    f"{path}:{line_number}: missing field(s): {', '.join(missing)}"
                )
            forbidden = {"rule", "type"} & sample.keys()
            if forbidden:
                raise DatasetError(
                    f"{path}:{line_number}: non-target schema forbids "
                    + ", ".join(sorted(forbidden))
                )
            if any(
                not isinstance(sample[field], str) or not sample[field].strip()
                for field in NON_TARGET_STRING_FIELDS
            ):
                raise DatasetError(
                    f"{path}:{line_number}: id, task, input, and rubric must be non-empty strings"
                )
            excluded_rules = sample["excluded_rules"]
            if (
                not isinstance(excluded_rules, list)
                or not all(
                    isinstance(rule_id, str)
                    and RULE_ID_TOKEN_RE.fullmatch(rule_id.strip())
                    for rule_id in excluded_rules
                )
            ):
                raise DatasetError(
                    f"{path}:{line_number}: excluded_rules must be a list of rule IDs"
                )
            normalized = {
                field: sample[field].strip()
                for field in sorted(NON_TARGET_STRING_FIELDS)
            }
            normalized["excluded_rules"] = sorted({
                rule_id.strip().upper() for rule_id in excluded_rules
            })
            unknown_rules = sorted(
                set(normalized["excluded_rules"]) - known_rules
            )
            if unknown_rules:
                raise DatasetError(
                    f"{path}:{line_number}: unknown excluded rule ID(s): "
                    + ", ".join(unknown_rules)
                )
            if normalized["id"] in seen_ids:
                raise DatasetError(
                    f"{path}:{line_number}: duplicate sample id {normalized['id']!r}"
                )
            seen_ids.add(normalized["id"])
            samples.append(normalized)
    if not samples:
        raise DatasetError(f"Non-target dataset has no samples: {path}")
    return samples


def select_target_samples(samples: list[dict], candidate: str) -> list[dict]:
    return [sample for sample in samples if sample["rule"].upper() == candidate.upper()]


def select_non_target_samples(samples: list[dict], candidate: str) -> list[dict]:
    candidate_id = candidate.upper()
    return [
        sample for sample in samples
        if candidate_id not in sample["excluded_rules"]
    ]


def load_paired_thresholds(path: Path) -> dict[str, Any]:
    try:
        thresholds = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_json_keys,
        )
    except (OSError, json.JSONDecodeError, DuplicateJsonKeyError) as exc:
        raise PairedEvalError(f"invalid thresholds file {path}: {exc}") from exc
    if not isinstance(thresholds, dict) or set(thresholds) != THRESHOLD_KEYS:
        raise PairedEvalError(
            f"thresholds must contain exactly: {', '.join(sorted(THRESHOLD_KEYS))}"
        )
    if not isinstance(thresholds["calibrated"], bool):
        raise PairedEvalError("threshold calibrated must be boolean")
    for key in ("min_target_samples", "min_non_target_samples"):
        value = thresholds[key]
        if type(value) is not int or value <= 0:
            raise PairedEvalError(f"threshold {key} must be a positive integer")
    value = thresholds["max_cross_refs"]
    if type(value) is not int or value < 0:
        raise PairedEvalError(
            "threshold max_cross_refs must be a non-negative integer"
        )
    ratio_keys = THRESHOLD_KEYS - {
        "calibrated",
        "min_target_samples",
        "min_non_target_samples",
        "max_cross_refs",
    }
    for key in ratio_keys:
        value = thresholds[key]
        if (
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(float(value))
            or not 0 <= value <= 1
        ):
            raise PairedEvalError(f"threshold {key} must be finite and between 0 and 1")
    return thresholds


def validate_placebo_candidate(
    candidate: str,
    placebo_candidate: str,
    candidate_characters: int,
    placebo_characters: int,
    maximum_length_ratio: float,
) -> None:
    if candidate.upper() == placebo_candidate.upper():
        raise PairedEvalError("placebo candidate must differ from the candidate rule")
    denominator = max(candidate_characters, 1)
    length_ratio = abs(candidate_characters - placebo_characters) / denominator
    if length_ratio > maximum_length_ratio:
        raise PairedEvalError(
            f"placebo length ratio {length_ratio:.3f} exceeds "
            f"max_placebo_length_ratio={maximum_length_ratio}"
        )
    pair = frozenset((candidate.upper(), placebo_candidate.upper()))
    if pair not in APPROVED_PLACEBO_PAIRS:
        raise PairedEvalError(
            "placebo pair is not explicitly approved as semantically unrelated: "
            f"{candidate.upper()} / {placebo_candidate.upper()}"
        )


def validate_candidate_supported(candidate: str) -> None:
    compact_location = SHARED_CORE_RULE_EQUIVALENTS.get(candidate.upper())
    if compact_location:
        raise PairedEvalError(
            f"candidate {candidate.upper()} is unsupported because the shared compact "
            f"core retains equivalent semantics in {compact_location}"
        )


def assert_paired_identity(with_identity: dict[str, str], without_identity: dict[str, str]) -> None:
    for field in ("model", "dataset_digest", "sample_set_digest"):
        if with_identity[field] != without_identity[field]:
            raise PairedEvalError(f"paired input identity mismatch: {field}")
    if with_identity["rule_digest"] == without_identity["rule_digest"]:
        raise PairedEvalError("paired input identity mismatch: rule_digest must differ")


def _identity(
    model: str,
    rules: str,
    dataset_path: Path,
    samples: list[dict],
) -> dict[str, str]:
    return {
        "model": model,
        "rule_digest": sha256_text(rules),
        "dataset_digest": file_digest(dataset_path),
        "sample_set_digest": sample_set_digest(samples),
    }


def _print_removal_evidence(evidence: dict[str, Any]) -> None:
    checks = ", ".join(
        f"{name}={status}" for name, status in evidence["assertions"].items()
    )
    print(f"Removal assertions: {checks}")
    print(f"Cross references ({len(evidence['cross_references'])}):")
    for reference in evidence["cross_references"]:
        print(f"  - {reference}")
    shells = ", ".join(evidence["empty_shells"]) or "none"
    print(f"Empty-shell rule files: {shells}")


def _build_parser(default_model: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="VibeGuard paired with/without rule evaluation"
    )
    parser.add_argument("--candidate", required=True, help="Exact native rule ID")
    parser.add_argument("--placebo-candidate", help="Similar-length unrelated rule for calibration")
    parser.add_argument("--model", default=default_model, help="Producer model alias or ID")
    parser.add_argument("--judge-model", help="Required for a real run")
    parser.add_argument("--dry-run", action="store_true", help="Validate inputs without API calls")
    parser.add_argument("--target-dataset", default=str(DEFAULT_TARGET_DATASET))
    parser.add_argument("--non-target-dataset", default=str(DEFAULT_NON_TARGET_DATASET))
    parser.add_argument("--thresholds", default=str(DEFAULT_THRESHOLDS))
    parser.add_argument("--rules-dir", default=str(DEFAULT_RULES_DIR))
    parser.add_argument("--core-rules-file", default=str(DEFAULT_CORE_RULES_FILE))
    parser.add_argument("--artifact-root", default=str(DEFAULT_ARTIFACT_ROOT))
    return parser


def _run_dry_or_prepare(
    args: argparse.Namespace,
    *,
    startup_commit: str | None = None,
    startup_commit_error: str | None = None,
) -> int:
    baseline = load_model_baseline()
    producer_model = baseline.resolve(args.model)
    if not args.dry_run and not args.judge_model:
        raise PairedEvalError("real runs require --judge-model")
    judge_model = baseline.resolve(args.judge_model) if args.judge_model else None
    rules_dir = absolute_without_leaf_resolution(Path(args.rules_dir))
    core_file = absolute_without_leaf_resolution(Path(args.core_rules_file))
    target_path = absolute_without_leaf_resolution(Path(args.target_dataset))
    non_target_path = absolute_without_leaf_resolution(Path(args.non_target_dataset))
    thresholds_path = absolute_without_leaf_resolution(Path(args.thresholds))
    evaluated_input_paths = _evaluated_provenance_paths(
        rules_dir=rules_dir,
        core_file=core_file,
        target_path=target_path,
        non_target_path=non_target_path,
        thresholds_path=thresholds_path,
    )
    evaluated_commit = None
    if not args.dry_run:
        if startup_commit_error:
            raise PairedEvalError(
                f"cannot capture commit before evaluator imports: {startup_commit_error}"
            )
        if not startup_commit:
            raise PairedEvalError(
                "real runs require a commit captured before evaluator imports"
            )
        evaluated_commit = pin_evaluated_inputs(
            evaluated_input_paths,
            expected_commit=startup_commit,
            repo_root=REPO_ROOT,
            markdown_roots=[rules_dir],
        )
    thresholds = load_paired_thresholds(thresholds_path)
    validate_candidate_supported(args.candidate)
    known_rule_ids = set(canonical_rule_inventory(rules_dir))
    target_samples = select_target_samples(load_dataset(target_path), args.candidate)
    non_target_samples = select_non_target_samples(
        load_non_target_dataset(non_target_path, known_rule_ids), args.candidate
    )
    if not target_samples and not non_target_samples:
        raise PairedEvalError("target and non-target sample sets are both empty")

    with tempfile.TemporaryDirectory(prefix="vibeguard-paired-") as tmp:
        evidence = prepare_without_rules(
            rules_dir, core_file, args.candidate, Path(tmp) / "candidate"
        )
        with_rules = load_rules(rules_dir, core_file)
        without_rules = load_rules(evidence["rules_dir"], evidence["core_file"])
        target_with = _identity(producer_model, with_rules, target_path, target_samples)
        target_without = _identity(producer_model, without_rules, target_path, target_samples)
        non_target_with = _identity(
            producer_model, with_rules, non_target_path, non_target_samples
        )
        non_target_without = _identity(
            producer_model, without_rules, non_target_path, non_target_samples
        )
        assert_paired_identity(target_with, target_without)
        assert_paired_identity(non_target_with, non_target_without)

        placebo = None
        placebo_rules = None
        if args.placebo_candidate:
            validate_candidate_supported(args.placebo_candidate)
            if args.placebo_candidate.upper() == args.candidate.upper():
                raise PairedEvalError(
                    "placebo candidate must differ from the candidate rule"
                )
            placebo = prepare_without_rules(
                rules_dir,
                core_file,
                args.placebo_candidate,
                Path(tmp) / "placebo",
            )
            placebo_rules = load_rules(placebo["rules_dir"], placebo["core_file"])
            validate_placebo_candidate(
                args.candidate,
                args.placebo_candidate,
                len(with_rules) - len(without_rules),
                len(with_rules) - len(placebo_rules),
                thresholds["max_placebo_length_ratio"],
            )
            if cross_reference_limit_exceeded(
                placebo, int(thresholds["max_cross_refs"])
            ):
                raise PairedEvalError(
                    "placebo cross references exceed max_cross_refs"
                )

        print(
            "Paired runs: target-with, target-without, "
            "non-target-with, non-target-without"
        )
        print(f"Candidate: {args.candidate.upper()}")
        _print_removal_evidence(evidence)
        print(f"Target samples: {len(target_samples)}")
        print(f"Non-target samples: {len(non_target_samples)}")
        print(f"Target dataset digest: {target_with['dataset_digest']}")
        print(f"Target sample digest: {target_with['sample_set_digest']}")
        print(f"Non-target dataset digest: {non_target_with['dataset_digest']}")
        print(f"Non-target sample digest: {non_target_with['sample_set_digest']}")
        for label, identity in (
            ("target-with", target_with),
            ("target-without", target_without),
            ("non-target-with", non_target_with),
            ("non-target-without", non_target_without),
        ):
            print(f"{label} identity: {json.dumps(identity, sort_keys=True)}")
        print(f"Producer model: {producer_model}")
        print(f"Judge model: {judge_model or 'not required for dry-run'}")
        print(f"Judge prompt digest: {sha256_text(build_judge_prompt())}")
        print(
            "Rule text characters: "
            f"with={len(with_rules)}, without={len(without_rules)}, "
            f"delta={len(with_rules) - len(without_rules)}"
        )
        print(f"Thresholds calibrated: {str(thresholds['calibrated']).lower()}")
        if placebo:
            print(f"Placebo candidate: {args.placebo_candidate.upper()}")
            print(
                "Placebo rule text character delta: "
                f"{len(with_rules) - len(placebo_rules)} "
                f"(candidate={len(with_rules) - len(without_rules)})"
            )
        else:
            print("Placebo candidate: not supplied; required for threshold calibration")

        if args.dry_run:
            print("Verdict: not produced in dry-run")
            return 0

        placebo_payload = None
        if placebo:
            placebo_identity = _identity(
                producer_model, placebo_rules, target_path, target_samples
            )
            assert_paired_identity(target_with, placebo_identity)
            placebo_payload = {
                "candidate": args.placebo_candidate.upper(),
                "rules": placebo_rules,
                "identity": placebo_identity,
                "evidence": placebo,
            }
        pin_evaluated_inputs(
            evaluated_input_paths,
            expected_commit=evaluated_commit,
            repo_root=REPO_ROOT,
            markdown_roots=[rules_dir],
        )
        return execute_real_run(
            producer_model=producer_model,
            judge_model=judge_model,
            candidate=args.candidate.upper(),
            with_rules=with_rules,
            without_rules=without_rules,
            target_samples=target_samples,
            non_target_samples=non_target_samples,
            identities={
                "target_with": target_with,
                "target_without": target_without,
                "non_target_with": non_target_with,
                "non_target_without": non_target_without,
            },
            thresholds=thresholds,
            removal_evidence=evidence,
            cross_refs_exceeded=cross_reference_limit_exceeded(
                evidence, int(thresholds["max_cross_refs"])
            ),
            artifact_root=Path(args.artifact_root).resolve(),
            placebo=placebo_payload,
            evaluated_commit=evaluated_commit,
        )


def main(
    *,
    startup_commit: str | None = None,
    startup_commit_error: str | None = None,
) -> int:
    try:
        baseline = load_model_baseline()
        args = _build_parser(baseline.default_alias).parse_args()
        return _run_dry_or_prepare(
            args,
            startup_commit=startup_commit,
            startup_commit_error=startup_commit_error,
        )
    except (
        DatasetError,
        ModelBaselineError,
        PairedEvalError,
        PairedExecutionError,
        PairedProvenanceError,
    ) as exc:
        print(f"Paired eval error: {exc}", file=sys.stderr)
        return 2
