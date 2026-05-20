#!/usr/bin/env python3
"""Score proposed skill changes with repair/regression evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path


OUTCOMES = {"success", "failure"}
DEFAULT_OUTPUT_DIR = ".vibeguard/skill-validate"
FORMAT_PATH_PATTERNS = ("skills/*/SKILL.md", "workflows/*/SKILL.md")
FORMAT_REQUIRED_SECTIONS = ("## When to Activate", "## Red Flags", "## Checklist")
FORMAT_LIST_SECTIONS = ("## Red Flags", "## Checklist")


class SkillValidateError(Exception):
    """Raised for invalid validation inputs."""


def read_jsonl(path: Path, source_name: str) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise SkillValidateError(f"cannot read {source_name} file {path}: {exc}") from exc
    for index, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SkillValidateError(f"{path}:{index}: invalid JSON: {exc}") from exc
        if not isinstance(value, dict):
            raise SkillValidateError(f"{path}:{index}: each JSONL line must be an object")
        value["_source"] = source_name
        value["_line"] = index
        records.append(value)
    if not records:
        raise SkillValidateError(f"{source_name} file has no records: {path}")
    return records


def outcome_from(value: object, field_name: str, record_id: str) -> str:
    raw = value
    if isinstance(value, dict):
        raw = value.get("outcome")
    if not isinstance(raw, str):
        raise SkillValidateError(f"{record_id}: {field_name} must contain an outcome string")
    outcome = raw.strip().lower()
    if outcome not in OUTCOMES:
        raise SkillValidateError(f"{record_id}: {field_name} outcome must be success or failure")
    return outcome


def record_id(record: dict[str, object]) -> str:
    scenario_id = record.get("scenario_id") or record.get("id")
    source = record.get("_source", "records")
    line = record.get("_line", "?")
    return str(scenario_id or f"{source}:{line}")


def parse_date(value: object, record_label: str) -> dt.date | None:
    if value in (None, ""):
        return None
    if not isinstance(value, str):
        raise SkillValidateError(f"{record_label}: scored_at must be an ISO date string")
    try:
        return dt.date.fromisoformat(value[:10])
    except ValueError as exc:
        raise SkillValidateError(f"{record_label}: scored_at must start with YYYY-MM-DD") from exc


def classify_record(record: dict[str, object]) -> dict[str, object]:
    label = record_id(record)
    without = outcome_from(
        record.get("without_skill", record.get("baseline")),
        "without_skill",
        label,
    )
    with_skill = outcome_from(
        record.get("with_skill", record.get("intervention")),
        "with_skill",
        label,
    )
    if without == "failure" and with_skill == "success":
        classification = "repair"
    elif without == "success" and with_skill == "failure":
        classification = "regression"
    else:
        classification = "no_change"
    scenario_type = str(record.get("scenario_type") or "target").strip().lower()
    return {
        "scenario_id": label,
        "scenario_type": scenario_type,
        "without_skill": without,
        "with_skill": with_skill,
        "classification": classification,
        "source": record.get("_source", "records"),
        "scored_against_agent": record.get("scored_against_agent"),
        "scored_at": record.get("scored_at"),
        "notes": record.get("notes"),
    }


def freshness_gaps(
    records: list[dict[str, object]],
    current_agent: str | None,
    as_of: dt.date,
    max_age_days: int | None,
) -> list[str]:
    gaps: list[str] = []
    for record in records:
        label = record_id(record)
        scored_agent = record.get("scored_against_agent")
        if current_agent:
            if not scored_agent:
                gaps.append(f"{label}: missing scored_against_agent")
            elif str(scored_agent) != current_agent:
                gaps.append(f"{label}: scored against {scored_agent}, not {current_agent}")
        scored_at = parse_date(record.get("scored_at"), label)
        if max_age_days is not None:
            if scored_at is None:
                gaps.append(f"{label}: missing scored_at")
            elif (as_of - scored_at).days > max_age_days:
                gaps.append(f"{label}: scored_at is older than {max_age_days} days")
    return gaps


def count_classifications(classified: list[dict[str, object]]) -> dict[str, int]:
    counts = {"repair": 0, "regression": 0, "no_change": 0, "unrelated_regression": 0}
    for item in classified:
        classification = str(item["classification"])
        counts[classification] += 1
        if classification == "regression" and item.get("scenario_type") == "unrelated":
            counts["unrelated_regression"] += 1
    return counts


def extract_skill_name(path: Path) -> str:
    if not path.is_file():
        raise SkillValidateError(f"proposed skill does not exist: {path}")
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SkillValidateError(f"cannot read proposed skill {path}: {exc}") from exc
    if not text.lstrip().startswith("---"):
        raise SkillValidateError("proposed skill must have YAML frontmatter")
    match = re.search(r"(?m)^name:\s*['\"]?([^'\"\n]+)['\"]?\s*$", text)
    if match:
        return match.group(1).strip()
    if path.parent.name:
        return path.parent.name
    raise SkillValidateError("cannot infer skill name")


def markdown_sections(text: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {}
    current: str | None = None
    for line in text.splitlines():
        if line.startswith("## "):
            current = line.strip()
            sections[current] = []
            continue
        if current is not None:
            sections[current].append(line)
    return sections


def useful_list_item(line: str) -> bool:
    match = re.match(r"^\s*(?:[-*+]|\d+[.)])\s+(?P<item>\S.*)$", line)
    if not match:
        return False
    item = re.sub(r"^\[[ xX]\]\s+", "", match.group("item").strip())
    lower = item.strip(" .").lower()
    if not lower or lower in {"...", "todo", "tbd", "n/a", "none", "placeholder"}:
        return False
    if lower.startswith(("todo:", "tbd:", "[", "<")):
        return False
    return True


def skill_format_errors(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"cannot read skill file: {exc}"]
    sections = markdown_sections(text)
    errors: list[str] = []
    for heading in FORMAT_REQUIRED_SECTIONS:
        body = sections.get(heading)
        if body is None:
            errors.append(f"missing required section: {heading}")
            continue
        if not any(line.strip() for line in body):
            errors.append(f"{heading} is empty")
    for heading in FORMAT_LIST_SECTIONS:
        body = sections.get(heading)
        if body is not None and not any(useful_list_item(line) for line in body):
            errors.append(f"{heading} has no useful list items")
    return errors


def repo_skill_paths(repo_root: Path) -> list[Path]:
    paths: list[Path] = []
    for pattern in FORMAT_PATH_PATTERNS:
        paths.extend(repo_root.glob(pattern))
    return sorted(path for path in paths if path.is_file())


def build_format_artifact(paths: list[Path], repo_root: Path | None) -> dict[str, object]:
    errors: list[dict[str, str]] = []
    for path in paths:
        display_path = str(path.relative_to(repo_root)) if repo_root else str(path)
        for message in skill_format_errors(path):
            errors.append({"path": display_path, "message": message})
    verdict = "pass" if not errors and paths else "fail"
    if not paths:
        errors.append({"path": str(repo_root or "."), "message": "no skill files found"})
    return {
        "command": "skill_validate",
        "mode": "format",
        "verdict": verdict,
        "paths_checked": len(paths),
        "required_sections": list(FORMAT_REQUIRED_SECTIONS),
        "list_required_sections": list(FORMAT_LIST_SECTIONS),
        "errors": errors,
    }


def print_format_report(artifact: dict[str, object]) -> None:
    print("SKILL-FORMAT")
    print(f"verdict: {artifact['verdict']}")
    print(f"paths_checked: {artifact['paths_checked']}")
    print("required_sections:")
    for heading in artifact["required_sections"]:
        print(f"- {heading}")
    print("list_required_sections:")
    for heading in artifact["list_required_sections"]:
        print(f"- {heading}")
    print("errors:")
    errors = artifact["errors"]
    if errors:
        for error in errors:
            print(f"- {error['path']}: {error['message']}")
    else:
        print("- none")


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "-", value.strip().lower()).strip("-")
    return slug or "skill"


def determine_verdict(
    counts: dict[str, int],
    stale_gaps: list[str],
    allow_stale: bool,
    regression_justification: str | None,
) -> tuple[str, list[str]]:
    reasons: list[str] = []
    repairs = counts["repair"]
    regressions = counts["regression"]
    unrelated_regressions = counts["unrelated_regression"]

    if stale_gaps and not allow_stale:
        return ("stale", ["freshness evidence is stale or incomplete"])
    if repairs == 0:
        return ("fail", ["repair count is zero"])
    if repairs <= regressions:
        return ("fail", ["repair count is not greater than regression count"])
    if unrelated_regressions > 0:
        return ("advisory", ["unrelated task regression requires advisory-only treatment"])
    if regressions > 0 and not regression_justification:
        return ("needs_justification", ["regression count is nonzero and no justification was provided"])
    if regressions > 0:
        reasons.append("accepted with written regression justification")
    else:
        reasons.append("repair count is greater than regression count with no regressions")
    return ("pass", reasons)


def write_artifact(artifact: dict[str, object], output_dir: Path, skill_name: str, as_of: dt.date) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / f"{slugify(skill_name)}-{as_of.isoformat()}.jsonl"
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(artifact, sort_keys=True) + "\n")
    return path


def print_report(artifact: dict[str, object], artifact_path: Path | None) -> None:
    counts = artifact["counts"]
    print(f"SKILL-VALIDATE {artifact['skill_name']}")
    print(f"verdict: {artifact['verdict']}")
    print(f"decision_set: {artifact['decision_set']}")
    print(f"artifact: {artifact_path if artifact_path else 'not written'}")
    print("counts:")
    for key in ("repair", "regression", "no_change", "unrelated_regression"):
        print(f"- {key}: {counts[key]}")
    print("reasons:")
    for reason in artifact["reasons"]:
        print(f"- {reason}")
    print("freshness_gaps:")
    gaps = artifact["freshness_gaps"]
    if gaps:
        for gap in gaps:
            print(f"- {gap}")
    else:
        print("- none")
    print("scenarios:")
    for item in artifact["scenarios"]:
        print(
            "- {scenario_id}: {classification} ({without_skill} -> {with_skill}, {scenario_type})".format(
                **item,
            )
        )


def build_artifact(args: argparse.Namespace) -> tuple[dict[str, object], Path | None]:
    proposed_skill = Path(args.proposed_skill).resolve()
    skill_name = extract_skill_name(proposed_skill)
    format_errors = skill_format_errors(proposed_skill)
    if format_errors:
        joined = "; ".join(format_errors)
        raise SkillValidateError(f"proposed skill format failed: {joined}")
    as_of = dt.date.fromisoformat(args.as_of) if args.as_of else dt.date.today()
    baseline_records = read_jsonl(Path(args.baseline_trajectories), "baseline")
    held_out_records = read_jsonl(Path(args.held_out), "held_out") if args.held_out else []
    decision_records = held_out_records or baseline_records
    decision_set = "held_out" if held_out_records else "baseline"

    stale_gaps = freshness_gaps(
        decision_records,
        args.current_agent,
        as_of,
        args.max_age_days,
    )
    classified = [classify_record(record) for record in decision_records]
    counts = count_classifications(classified)
    verdict, reasons = determine_verdict(
        counts,
        stale_gaps,
        args.allow_stale,
        args.regression_justification,
    )
    artifact: dict[str, object] = {
        "command": "skill_validate",
        "skill_name": skill_name,
        "proposed_skill": str(proposed_skill),
        "decision_set": decision_set,
        "verdict": verdict,
        "counts": counts,
        "freshness_gaps": stale_gaps,
        "reasons": reasons,
        "regression_justification": args.regression_justification,
        "scored_against_agent": args.current_agent,
        "scored_at": as_of.isoformat(),
        "scenarios": classified,
    }
    artifact_path = None
    if not args.no_persist:
        artifact_path = write_artifact(artifact, Path(args.output_dir), skill_name, as_of)
        artifact["artifact_path"] = str(artifact_path)
    return artifact, artifact_path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate proposed skill format and score repair/regression evidence.",
    )
    parser.add_argument("--proposed-skill", help="Path to draft SKILL.md")
    parser.add_argument("--baseline-trajectories", help="JSONL with paired without/with outcomes")
    parser.add_argument("--held-out", help="Optional held-out JSONL used for the final verdict")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR, help="Directory for verdict JSONL artifacts")
    parser.add_argument("--no-persist", action="store_true", help="Print only; do not write an artifact")
    parser.add_argument("--current-agent", help="Expected agent/model identifier for freshness checks")
    parser.add_argument("--max-age-days", type=int, default=90, help="Mark records stale after N days")
    parser.add_argument("--as-of", help="Evaluation date, YYYY-MM-DD; defaults to today")
    parser.add_argument("--allow-stale", action="store_true", help="Report stale gaps without failing the verdict")
    parser.add_argument("--regression-justification", help="Required when regression count is nonzero")
    format_group = parser.add_mutually_exclusive_group()
    format_group.add_argument(
        "--format-only",
        action="store_true",
        help="Validate only the required SKILL.md structural sections.",
    )
    format_group.add_argument(
        "--check-repo-format",
        action="store_true",
        help="Validate skills/*/SKILL.md and workflows/*/SKILL.md under --repo-root.",
    )
    parser.add_argument("--repo-root", default=".", help="Repository root for --check-repo-format")
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.check_repo_format:
        repo_root = Path(args.repo_root).resolve()
        artifact = build_format_artifact(repo_skill_paths(repo_root), repo_root)
        print_format_report(artifact)
        return 0 if artifact["verdict"] == "pass" else 1
    if args.format_only:
        if not args.proposed_skill:
            parser.error("--format-only requires --proposed-skill")
        artifact = build_format_artifact([Path(args.proposed_skill).resolve()], None)
        print_format_report(artifact)
        return 0 if artifact["verdict"] == "pass" else 1
    if not args.proposed_skill:
        parser.error("--proposed-skill is required unless --check-repo-format is used")
    if not args.baseline_trajectories:
        parser.error("--baseline-trajectories is required unless --format-only or --check-repo-format is used")
    try:
        artifact, artifact_path = build_artifact(args)
    except SkillValidateError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print_report(artifact, artifact_path)
    return 0 if artifact["verdict"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
