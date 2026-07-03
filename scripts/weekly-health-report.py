#!/usr/bin/env python3
"""Render a weekly VibeGuard health report from existing local evidence."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent
RULE_ID_RE = re.compile(r"\b[A-Z]{1,5}-\d{1,4}\b")
RULE_HEADING_RE = re.compile(r"^##\s+([A-Z]{1,5}-\d{1,4}):", re.MULTILINE)
TEXT_SKILL_RE_TEMPLATE = r"(?<![A-Za-z0-9_-]){name}(?![A-Za-z0-9_-])"


class ReportError(RuntimeError):
    pass


@dataclass(frozen=True)
class SkillItem:
    name: str
    path: str


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render a weekly system health report from VibeGuard observe, precision, and skill evidence."
    )
    parser.add_argument("--runtime", required=True, help="path to vibeguard-runtime")
    parser.add_argument("--days", type=positive_int, default=30, help="lookback window in days")
    parser.add_argument("--scope", choices=["project", "global"], help="observe log scope")
    parser.add_argument("--project", help="project path or project log hash for project scope")
    parser.add_argument("--log-file", type=Path, help="explicit events.jsonl path")
    parser.add_argument("--triage-file", type=Path, default=REPO_DIR / "data" / "triage.jsonl")
    parser.add_argument("--scorecard-file", type=Path, default=REPO_DIR / "data" / "rule-scorecard.json")
    parser.add_argument("--rules-dir", type=Path, default=REPO_DIR / "rules" / "claude-rules")
    parser.add_argument(
        "--skills-dir",
        action="append",
        type=Path,
        help="skill root to include; may be repeated. Defaults to repository skill roots.",
    )
    parser.add_argument("--top", type=positive_int, default=10, help="number of hot rows to show")
    parser.add_argument(
        "--fp-rate-threshold",
        type=fp_rate_threshold,
        default=0.20,
        help="FP rate threshold for the precision attention section",
    )
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    return parser.parse_args(argv)


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def fp_rate_threshold(value: str) -> float:
    parsed = float(value)
    if parsed < 0 or parsed > 1:
        raise argparse.ArgumentTypeError("must be between 0 and 1")
    return parsed


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        report = build_report(args)
    except ReportError as exc:
        print(f"weekly-health-report: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render_human(report))
    return 0


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    summary = run_observe_summary(args)
    log_path = resolve_log_path(args.log_file, summary)
    events, event_diagnostics = load_events(log_path, args.days)
    rule_triggers = build_rule_triggers(events)
    precision = build_precision_attention(args)
    skill_inventory = load_skill_inventory(args.skills_dir)
    used_skills = extract_used_skills(events, skill_inventory)
    if event_diagnostics["event_source_exists"]:
        zero_rules = build_zero_rule_candidates(args.rules_dir, rule_triggers)
        zero_skills = [
            {"name": item.name, "path": item.path}
            for item in skill_inventory
            if item.name not in used_skills
        ]
    else:
        zero_rules = []
        zero_skills = []

    return {
        "schema_version": 1,
        "report": "weekly_health",
        "window": {"days": args.days},
        "source": {
            "observe": summary.get("source", {}),
            "log_path": str(log_path) if log_path is not None else "",
            **event_diagnostics,
            "triage_file": str(args.triage_file),
            "scorecard_file": str(args.scorecard_file),
            "rules_dir": str(args.rules_dir),
            "skills_dirs": [str(path) for path in effective_skill_dirs(args.skills_dir)],
            "top": args.top,
        },
        "runtime_summary": {
            "event_count": summary.get("event_count", 0),
            "decision_counts": summary.get("decision_counts", {}),
            "hook_counts": summary.get("hook_counts", {}),
            "attention": summary.get("attention", {}),
            "top_rule_ids": summary.get("top_rule_ids", []),
        },
        "rule_triggers": rule_triggers,
        "precision_attention": precision,
        "zero_usage": {
            "rules": {
                "lookback_days": args.days,
                "count": len(zero_rules),
                "items": zero_rules,
            },
            "skills": {
                "lookback_days": args.days,
                "count": len(zero_skills),
                "items": zero_skills,
            },
        },
    }


def run_observe_summary(args: argparse.Namespace) -> dict[str, Any]:
    command = [
        str(args.runtime),
        "observe",
        "summary",
        "--json",
        "--days",
        str(args.days),
        "--limit",
        "all",
        "--top",
        str(max(args.top, 1000)),
    ]
    if args.scope:
        command.extend(["--scope", args.scope])
    if args.project:
        command.extend(["--project", args.project])
    if args.log_file:
        command.extend(["--log-file", str(args.log_file)])
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise ReportError(f"runtime not found: {args.runtime}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        raise ReportError(f"observe summary failed: {detail}") from exc
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise ReportError("observe summary did not return JSON") from exc
    if not isinstance(payload, dict):
        raise ReportError("observe summary returned a non-object payload")
    return payload


def resolve_log_path(explicit: Path | None, summary: dict[str, Any]) -> Path | None:
    if explicit is not None:
        return explicit
    raw = summary.get("source", {}).get("log_path", "")
    if not isinstance(raw, str) or not raw:
        return None
    if raw.startswith("~/"):
        return Path.home() / raw[2:]
    return Path(raw)


def load_events(path: Path | None, days: int) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    diagnostics = {
        "event_source_exists": False,
        "event_parse_errors": 0,
        "event_non_object_lines": 0,
        "event_timestamp_skips": 0,
        "events_loaded_for_window": 0,
    }
    if path is None or not path.exists():
        return [], diagnostics
    diagnostics["event_source_exists"] = True
    cutoff = now_utc() - timedelta(days=days)
    events: list[dict[str, Any]] = []
    with path.open("rb") as handle:
        for raw_line in handle:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                diagnostics["event_parse_errors"] += 1
                continue
            if not isinstance(value, dict):
                diagnostics["event_non_object_lines"] += 1
                continue
            ts = parse_timestamp(str(value.get("ts", "")))
            if ts is None or ts < cutoff:
                diagnostics["event_timestamp_skips"] += 1
                continue
            events.append(value)
    diagnostics["events_loaded_for_window"] = len(events)
    return events, diagnostics


def now_utc() -> datetime:
    raw = os.environ.get("_VIBEGUARD_TEST_NOW")
    if raw:
        parsed = parse_timestamp(raw)
        if parsed is None:
            raise ReportError("_VIBEGUARD_TEST_NOW must be an ISO-8601 timestamp")
        return parsed
    return datetime.now(timezone.utc)


def parse_timestamp(value: str) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def build_rule_triggers(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    counts: dict[str, Counter[str]] = defaultdict(Counter)
    for event in events:
        reason = string_field(event, "reason")
        rule_ids = sorted(set(RULE_ID_RE.findall(reason.upper())))
        if not rule_ids:
            continue
        decision = normalized_decision(event)
        for rule_id in rule_ids:
            counts[rule_id][decision] += 1

    rows: list[dict[str, Any]] = []
    for rule_id, counter in counts.items():
        known = sum(counter.get(name, 0) for name in ["pass", "warn", "block"])
        total = sum(counter.values())
        rows.append(
            {
                "rule": rule_id,
                "total": total,
                "pass": counter.get("pass", 0),
                "warn": counter.get("warn", 0),
                "block": counter.get("block", 0),
                "other": total - known,
            }
        )
    rows.sort(key=lambda row: (-row["total"], row["rule"]))
    return rows


def normalized_decision(event: dict[str, Any]) -> str:
    for key in ["decision", "status"]:
        value = string_field(event, key).lower()
        if value:
            return value
    return "unknown"


def string_field(event: dict[str, Any], key: str) -> str:
    value = event.get(key, "")
    return value.strip() if isinstance(value, str) else ""


def build_precision_attention(args: argparse.Namespace) -> list[dict[str, Any]]:
    tracker = load_precision_tracker()
    triage_records, triage_errors = tracker.load_triage(args.triage_file)
    if triage_errors:
        raise ReportError(f"{triage_errors} invalid triage line(s); fix {args.triage_file}")
    scorecard = tracker.load_scorecard(args.scorecard_file)
    triage_stats = tracker.compute_rule_stats(triage_records)
    unclassified = Counter(
        rec.get("rule", "")
        for rec in triage_records
        if rec.get("verdict") == "unclassified" and isinstance(rec.get("rule"), str)
    )

    rules = set(scorecard.get("rules", {}).keys()) | set(triage_stats.keys()) | set(unclassified.keys())
    rows: list[dict[str, Any]] = []
    for rule in sorted(rules):
        score_entry = scorecard.get("rules", {}).get(rule, {})
        stats = triage_stats.get(rule)
        if stats:
            tp = int(stats.get("tp", 0))
            fp = int(stats.get("fp", 0))
            acceptable = int(stats.get("acceptable", 0))
            precision = tracker.precision_of(tp, fp)
            samples = tp + fp + acceptable
        else:
            tp = int(score_entry.get("tp", 0) or 0)
            fp = int(score_entry.get("fp", 0) or 0)
            acceptable = int(score_entry.get("acceptable", 0) or 0)
            precision = score_entry.get("precision")
            samples = int(score_entry.get("samples", 0) or 0)
        fp_rate = fp / (tp + fp) if (tp + fp) else None
        backlog = int(unclassified.get(rule, 0))
        if fp == 0 and backlog == 0 and not (fp_rate is not None and fp_rate >= args.fp_rate_threshold):
            continue
        rows.append(
            {
                "rule": rule,
                "stage": str(score_entry.get("stage", "")),
                "precision": round(precision, 4) if isinstance(precision, (int, float)) else None,
                "fp_rate": round(fp_rate, 4) if fp_rate is not None else None,
                "tp": tp,
                "fp": fp,
                "acceptable": acceptable,
                "samples": samples,
                "unclassified": backlog,
            }
        )
    rows.sort(
        key=lambda row: (
            -row["unclassified"],
            -(row["fp_rate"] if row["fp_rate"] is not None else -1),
            -row["fp"],
            row["rule"],
        )
    )
    return rows


def load_precision_tracker() -> Any:
    path = SCRIPT_DIR / "precision-tracker.py"
    spec = importlib.util.spec_from_file_location("precision_tracker", path)
    if spec is None or spec.loader is None:
        raise ReportError(f"cannot load precision tracker from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_zero_rule_candidates(rules_dir: Path, rule_triggers: list[dict[str, Any]]) -> list[str]:
    canonical = load_canonical_rule_ids(rules_dir)
    triggered = {str(row["rule"]) for row in rule_triggers}
    return sorted(canonical - triggered)


def load_canonical_rule_ids(rules_dir: Path) -> set[str]:
    if not rules_dir.exists():
        raise ReportError(f"rules directory does not exist: {rules_dir}")
    rules: set[str] = set()
    for path in sorted(rules_dir.rglob("*.md")):
        rules.update(RULE_HEADING_RE.findall(path.read_text(encoding="utf-8")))
    return rules


def effective_skill_dirs(skill_dirs: list[Path] | None) -> list[Path]:
    if skill_dirs:
        return skill_dirs
    return [
        REPO_DIR / "skills",
        REPO_DIR / "workflows",
        REPO_DIR / ".claude" / "skills",
        REPO_DIR / "plugins" / "vibeguard" / "skills",
    ]


def load_skill_inventory(skill_dirs: list[Path] | None) -> list[SkillItem]:
    items: list[SkillItem] = []
    seen_paths: set[str] = set()
    for root in effective_skill_dirs(skill_dirs):
        if not root.exists():
            continue
        for skill_file in sorted(root.rglob("SKILL.md")):
            rel = relative_repo_path(skill_file.parent)
            if rel in seen_paths:
                continue
            seen_paths.add(rel)
            items.append(SkillItem(name=skill_name(skill_file), path=rel))
    items.sort(key=lambda item: (item.name, item.path))
    return items


def relative_repo_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_DIR.resolve()))
    except ValueError:
        return str(path)


def skill_name(skill_file: Path) -> str:
    text = skill_file.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"^name:\s*['\"]?([^'\"\n]+)", text, re.MULTILINE)
    if match:
        return match.group(1).strip()
    return skill_file.parent.name


def extract_used_skills(events: list[dict[str, Any]], inventory: list[SkillItem]) -> set[str]:
    names = {item.name for item in inventory}
    used: set[str] = set()
    for event in events:
        used.update(extract_structured_skill_fields(event, names))
        if string_field(event, "hook") == "skills-loader":
            text = " ".join(string_field(event, key) for key in ["reason", "detail", "message", "output"])
            for name in names:
                if re.search(TEXT_SKILL_RE_TEMPLATE.format(name=re.escape(name)), text):
                    used.add(name)
    return used


def extract_structured_skill_fields(event: dict[str, Any], names: set[str]) -> set[str]:
    used: set[str] = set()
    for key in ["skill", "skill_name", "active_skill", "active_skills", "skills"]:
        value = event.get(key)
        candidates: list[str] = []
        if isinstance(value, str):
            candidates = re.split(r"[\s,]+", value.strip())
        elif isinstance(value, list):
            candidates = [item for item in value if isinstance(item, str)]
        for candidate in candidates:
            normalized = candidate.strip().lstrip("/")
            if normalized in names:
                used.add(normalized)
    return used


def render_human(report: dict[str, Any]) -> str:
    days = report["window"]["days"]
    source = report["source"]
    lines = [
        f"VibeGuard Weekly Health Report (last {days} days)",
        "=" * 52,
        f"Log: {source.get('log_path') or '(none)'}",
        f"Events loaded: {source['events_loaded_for_window']} "
        f"(parse errors: {source['event_parse_errors']}, non-object: {source['event_non_object_lines']})",
        "",
        "Rule trigger counts",
        "Rule        Total  Warn  Block  Pass  Other",
    ]
    for row in report["rule_triggers"][: report_top(report)]:
        lines.append(
            f"{row['rule']:<10} {row['total']:>5} {row['warn']:>5} {row['block']:>6} {row['pass']:>5} {row['other']:>6}"
        )
    if not report["rule_triggers"]:
        lines.append("(blank: no rule trigger data in the selected window)")

    lines.extend(["", "Precision attention", "Rule        FP rate  FP  TP  Acc  Unclassified  Stage"])
    for row in report["precision_attention"][: report_top(report)]:
        fp_rate = "N/A" if row["fp_rate"] is None else f"{row['fp_rate'] * 100:.1f}%"
        lines.append(
            f"{row['rule']:<10} {fp_rate:>7} {row['fp']:>3} {row['tp']:>3} "
            f"{row['acceptable']:>4} {row['unclassified']:>13}  {row['stage']}"
        )
    if not report["precision_attention"]:
        lines.append("(blank: no FP or unclassified precision backlog)")

    zero_rules = report["zero_usage"]["rules"]["items"]
    zero_skills = report["zero_usage"]["skills"]["items"]
    lines.extend(["", f"Zero-usage rule candidates ({len(zero_rules)})"])
    lines.extend(format_wrapped_items(zero_rules))
    lines.extend(["", f"Zero-usage skill candidates ({len(zero_skills)})"])
    lines.extend(format_wrapped_items([item["name"] for item in zero_skills]))
    return "\n".join(lines)


def report_top(report: dict[str, Any]) -> int:
    return int(report.get("source", {}).get("top", 10) or 10)


def format_wrapped_items(items: list[str]) -> list[str]:
    if not items:
        return ["(blank: no zero-usage candidates)"]
    return [f"- {item}" for item in items]


if __name__ == "__main__":
    sys.exit(main())
