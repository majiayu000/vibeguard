#!/usr/bin/env python3
"""
VibeGuard Weekly Health Report
==============================
A thin aggregator over existing structured sources — it adds no new data
layer. It reads:
  - `vibeguard-runtime observe summary --json --days N` for trigger counts and
    the pass/warn/block decision distribution
  - `vibeguard-runtime observe health --json` for recent diagnostics
  - triage.jsonl + rule-scorecard.json (via scripts/precision-tracker.py) for
    per-rule precision / FP risk and lifecycle stage
  - ~/.vibeguard/learn-adoptions.jsonl for skill adoption / zero-use evidence

It normalizes everything into one small JSON schema (see below) and renders
markdown from that same schema, so the two formats never drift.

Usage:
  python3 scripts/health-report.py                       # 30-day project report, markdown
  python3 scripts/health-report.py --days 7 --format json
  python3 scripts/health-report.py --scope global
  python3 scripts/health-report.py --log-file /path/events.jsonl --output report.md

Data rules (see docs/specs/GH556):
  - Missing event log is an explicit "no data" state, never success-with-zero.
  - Malformed triage JSONL or invalid scorecard JSON is a HARD ERROR (non-zero
    exit, error-level message). We never emit a misleading summary on top of
    unreadable evidence (U-29 / no silent degradation).
  - Project and global scopes stay explicit; they are never silently mixed.
  - Rule ids are primary keys. A triage candidate with no rule id lands in
    `unclassified_backlog`, it does not crash the precision pipeline.
  - The scorecard file is never mutated during report generation.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

# ---------------------------------------------------------------------------
# Paths (relative to repo root, resolved from script location)
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent
DEFAULT_TRIAGE_FILE = REPO_DIR / "data" / "triage.jsonl"
DEFAULT_SCORECARD_FILE = REPO_DIR / "data" / "rule-scorecard.json"
DEFAULT_SCORECARD_SEED_FILE = REPO_DIR / "data" / "rule-scorecard.seed.json"
DEFAULT_ADOPTIONS_FILE = Path.home() / ".vibeguard" / "learn-adoptions.jsonl"

# A rule with fewer than this many samples and precision below this threshold
# is flagged as a precision risk. Both borrow the precision-tracker demotion
# line so the two tools tell the same story.
PRECISION_RISK_THRESHOLD = 0.80

# Rules that never triggered inside a window this long are downgrade candidates.
ZERO_TRIGGER_MIN_DAYS = 30


class HealthReportError(RuntimeError):
    """Raised when a source is unreadable and a report must not be produced."""


# ---------------------------------------------------------------------------
# Reuse precision math from scripts/precision-tracker.py
# ---------------------------------------------------------------------------
# The file name is hyphenated so it is not importable by name; load it by path
# and reuse its pure helpers instead of duplicating the precision formula.

def _load_precision_tracker() -> Any:
    module_path = SCRIPT_DIR / "precision-tracker.py"
    spec = importlib.util.spec_from_file_location("vg_precision_tracker", module_path)
    if spec is None or spec.loader is None:
        raise HealthReportError(f"cannot load precision helpers from {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_PT = _load_precision_tracker()


# ---------------------------------------------------------------------------
# Runtime resolution (mirrors scripts/lib/runtime.sh candidate order)
# ---------------------------------------------------------------------------

def resolve_runtime() -> str:
    explicit = os.environ.get("VIBEGUARD_RUNTIME", "").strip()
    if explicit:
        if os.path.isabs(explicit) or "/" in explicit:
            if os.path.isfile(explicit) and os.access(explicit, os.X_OK):
                return explicit
            raise HealthReportError(f"VIBEGUARD_RUNTIME is not executable: {explicit}")
        return explicit
    candidates = []
    home = os.environ.get("HOME", "")
    if home:
        candidates.append(str(Path(home) / ".vibeguard" / "installed" / "bin" / "vibeguard-runtime"))
    candidates += [
        str(REPO_DIR / "vibeguard-runtime" / "target" / "release" / "vibeguard-runtime"),
        str(REPO_DIR / "vibeguard-runtime" / "target" / "debug" / "vibeguard-runtime"),
    ]
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return "vibeguard-runtime"


# ---------------------------------------------------------------------------
# observe summary / health adapters
# ---------------------------------------------------------------------------

def _run_observe(runtime: str, args: list[str]) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            [runtime, *args],
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise HealthReportError(f"runtime not found: {runtime} ({exc})") from exc
    return proc.returncode, proc.stdout, proc.stderr


def _looks_like_missing_log(stderr: str) -> bool:
    lowered = stderr.lower()
    return "does not exist" in lowered or "no such file" in lowered


def load_observe_summary(
    runtime: str,
    days: int,
    scope: str,
    project: str | None,
    log_file: str | None,
) -> tuple[dict[str, Any] | None, str]:
    """Return (summary_json_or_None, status).

    status is 'ok', 'no_data' (missing log), and any hard failure raises.
    """
    # A caller-supplied log path that does not exist is an explicit no-data
    # state, not a failure, and we must not fall back to an unrelated log.
    if log_file is not None and not Path(log_file).exists():
        return None, "no_data"

    args = ["observe", "summary", "--json", "--days", str(days), "--scope", scope]
    if project is not None:
        args += ["--project", project]
    if log_file is not None:
        args += ["--log-file", log_file]

    code, out, err = _run_observe(runtime, args)
    if code != 0:
        if _looks_like_missing_log(err):
            return None, "no_data"
        raise HealthReportError(f"observe summary failed (exit {code}): {err.strip()}")
    try:
        summary = json.loads(out)
    except json.JSONDecodeError as exc:
        raise HealthReportError(f"observe summary emitted invalid JSON: {exc}") from exc
    return summary, "ok"


def load_observe_health(
    runtime: str,
    scope: str,
    project: str | None,
    log_file: str | None,
) -> tuple[dict[str, Any] | None, str]:
    if log_file is not None and not Path(log_file).exists():
        return None, "no_data"
    args = ["observe", "health", "--json", "--scope", scope]
    if project is not None:
        args += ["--project", project]
    if log_file is not None:
        args += ["--log-file", log_file]
    code, out, err = _run_observe(runtime, args)
    if code != 0:
        if _looks_like_missing_log(err):
            return None, "no_data"
        raise HealthReportError(f"observe health failed (exit {code}): {err.strip()}")
    try:
        health = json.loads(out)
    except json.JSONDecodeError as exc:
        raise HealthReportError(f"observe health emitted invalid JSON: {exc}") from exc
    return health, "ok"


# ---------------------------------------------------------------------------
# Triage / precision adapter
# ---------------------------------------------------------------------------

def load_triage_partitioned(
    path: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Split triage.jsonl into (classified_records, backlog_records).

    - Unparseable JSON lines are a HARD ERROR (fail loudly): a corrupt line
      would silently deflate or inflate precision, so we refuse to guess.
    - Valid objects missing a rule id, or carrying an 'unclassified' verdict,
      are schema-gap backlog items — they keep the pipeline honest without
      crashing it (GH-555 rule-id coverage).
    - Everything else is a classified record fed to the precision math.
    """
    classified: list[dict[str, Any]] = []
    backlog: list[dict[str, Any]] = []
    if not path.exists():
        return classified, backlog
    with path.open(encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as exc:
                raise HealthReportError(
                    f"triage.jsonl line {lineno}: malformed JSON ({exc})"
                )
            if not isinstance(rec, dict):
                raise HealthReportError(
                    f"triage.jsonl line {lineno}: expected object, got {type(rec).__name__}"
                )
            rule = rec.get("rule")
            verdict = rec.get("verdict")
            if not isinstance(rule, str) or not rule.strip():
                backlog.append(
                    {
                        "line": lineno,
                        "reason": "missing rule id",
                        "verdict": verdict if isinstance(verdict, str) else None,
                        "ts": rec.get("ts"),
                        "context": rec.get("context") or rec.get("reason"),
                    }
                )
                continue
            if verdict == "unclassified":
                backlog.append(
                    {
                        "line": lineno,
                        "reason": "unclassified verdict",
                        "rule": rule,
                        "ts": rec.get("ts"),
                        "context": rec.get("context") or rec.get("reason"),
                    }
                )
                continue
            classified.append(rec)
    return classified, backlog


def load_scorecard(path: Path, seed_path: Path) -> dict[str, Any]:
    """Read a scorecard without mutating it. Invalid JSON is a hard error."""
    target = path
    if not path.exists() and seed_path.exists():
        target = seed_path
    if not target.exists():
        return {"rules": {}}
    try:
        with target.open(encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as exc:
        raise HealthReportError(f"invalid scorecard JSON in {target}: {exc}") from exc
    if not isinstance(data, dict):
        raise HealthReportError(f"scorecard {target} must be a JSON object")
    data.setdefault("rules", {})
    return data


def build_precision_risks(
    classified: list[dict[str, Any]],
    scorecard: dict[str, Any],
) -> list[dict[str, Any]]:
    """Per-rule precision/FP facts, merging live triage stats with scorecard stage."""
    stats = _PT.compute_rule_stats(classified)
    rules = scorecard.get("rules", {})
    rule_ids = sorted(set(stats) | set(rules))
    risks: list[dict[str, Any]] = []
    for rule in rule_ids:
        s = stats.get(rule, {"tp": 0, "fp": 0, "acceptable": 0, "last_fp_ts": None})
        entry = rules.get(rule, {})
        tp = s.get("tp", 0)
        fp = s.get("fp", 0)
        acceptable = s.get("acceptable", 0)
        samples = tp + fp + acceptable
        # Prefer live-triage precision; fall back to the stored scorecard value.
        precision = _PT.precision_of(tp, fp)
        if precision is None:
            precision = entry.get("precision")
        if samples == 0 and entry.get("samples"):
            samples = entry.get("samples", 0)
        risks.append(
            {
                "rule": rule,
                "stage": entry.get("stage", "experimental"),
                "precision": round(precision, 4) if isinstance(precision, float) else precision,
                "tp": tp,
                "fp": fp,
                "samples": samples,
                "last_fp_ts": s.get("last_fp_ts") or entry.get("last_fp_ts"),
                "at_risk": bool(
                    isinstance(precision, (int, float))
                    and precision < PRECISION_RISK_THRESHOLD
                    and samples > 0
                ),
            }
        )
    return risks


# ---------------------------------------------------------------------------
# Learn adoption adapter
# ---------------------------------------------------------------------------

def load_adoptions(path: Path) -> list[dict[str, Any]]:
    """Read Learn adoption JSONL. Unparseable lines are a hard error."""
    records: list[dict[str, Any]] = []
    if not path.exists():
        return records
    with path.open(encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as exc:
                raise HealthReportError(
                    f"learn-adoptions.jsonl line {lineno}: malformed JSON ({exc})"
                )
            if isinstance(rec, dict):
                records.append(rec)
    return records


def build_skill_usage(adoptions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Skills adopted but never verified are zero-use downgrade candidates.

    A skill is only "used" once a verify record with status 'verified' lands.
    Adopted-but-unverified skills stay listed as candidates, never auto-removed.
    """
    verified: set[str] = set()
    skills: dict[str, dict[str, Any]] = {}
    for rec in adoptions:
        signal_id = rec.get("signal_id")
        if not isinstance(signal_id, str):
            continue
        verification = rec.get("verification")
        if isinstance(verification, dict) and verification.get("status") == "verified":
            verified.add(signal_id)
        action = rec.get("selected_action")
        if isinstance(action, dict) and action.get("type") == "create_or_update_skill":
            artifacts = rec.get("files_or_artifacts") or []
            target = action.get("target")
            name = target if isinstance(target, str) and target else (
                artifacts[0] if artifacts else signal_id
            )
            skills[signal_id] = {"signal_id": signal_id, "skill": name}
    zero_use: list[dict[str, Any]] = []
    for signal_id, info in skills.items():
        if signal_id not in verified:
            zero_use.append({**info, "evidence": "adopted, no verified use"})
    return sorted(zero_use, key=lambda item: (item["skill"], item["signal_id"]))


# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------

def _observed_rule_ids(summary: dict[str, Any] | None) -> set[str]:
    if not summary:
        return set()
    ids = set()
    for entry in summary.get("top_rule_ids", []) or []:
        value = entry.get("value")
        if isinstance(value, str) and value:
            ids.add(value)
    return ids


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    runtime = resolve_runtime()
    triage_path = Path(args.triage_file)
    scorecard_path = Path(args.scorecard_file)
    adoptions_path = Path(args.adoptions_file)

    data_sources: list[dict[str, Any]] = []

    summary, summary_status = load_observe_summary(
        runtime, args.days, args.scope, args.project, args.log_file
    )
    data_sources.append({"name": "observe.summary", "status": summary_status})

    health, health_status = load_observe_health(
        runtime, args.scope, args.project, args.log_file
    )
    data_sources.append({"name": "observe.health", "status": health_status})

    classified, backlog = load_triage_partitioned(triage_path)
    scorecard = load_scorecard(scorecard_path, DEFAULT_SCORECARD_SEED_FILE)
    triage_present = triage_path.exists() or scorecard_path.exists()
    data_sources.append(
        {"name": "precision.triage", "status": "ok" if triage_present else "no_data"}
    )

    adoptions = load_adoptions(adoptions_path)
    data_sources.append(
        {"name": "learn.adoptions", "status": "ok" if adoptions_path.exists() else "no_data"}
    )

    # Overview -----------------------------------------------------------
    event_count = int(summary.get("event_count", 0)) if summary else 0
    no_data = summary is None or event_count == 0
    decision_counts = dict(summary.get("decision_counts", {})) if summary else {}
    time_range = summary.get("time_range", {}) if summary else {}
    attention = summary.get("attention", {}) if summary else {}
    overview = {
        "scope": args.scope,
        "window_days": args.days,
        "no_data": no_data,
        "total_triggers": event_count,
        "decision_distribution": decision_counts,
        "attention_rate": attention.get("rate"),
        "first_ts": time_range.get("first_ts") or None,
        "last_ts": time_range.get("last_ts") or None,
    }

    # Rule triggers (rule id is the primary key) -------------------------
    rule_triggers: list[dict[str, Any]] = []
    if summary:
        for entry in summary.get("top_rule_ids", []) or []:
            value = entry.get("value")
            if isinstance(value, str) and value:
                rule_triggers.append({"rule": value, "count": int(entry.get("count", 0))})
    rule_triggers.sort(key=lambda item: (-item["count"], item["rule"]))

    # Precision risks ----------------------------------------------------
    precision_risks = build_precision_risks(classified, scorecard)

    # Idle assets / downgrade candidates ---------------------------------
    observed = _observed_rule_ids(summary)
    zero_trigger_rules: list[dict[str, Any]] = []
    if args.days >= ZERO_TRIGGER_MIN_DAYS and not no_data:
        for rule in sorted(scorecard.get("rules", {})):
            if rule not in observed:
                entry = scorecard["rules"][rule]
                zero_trigger_rules.append(
                    {
                        "rule": rule,
                        "stage": entry.get("stage", "experimental"),
                        "evidence": f"no trigger in last {args.days} days",
                    }
                )
    zero_use_skills = build_skill_usage(adoptions)

    downgrade_candidates: list[dict[str, Any]] = []
    for item in zero_trigger_rules:
        downgrade_candidates.append(
            {
                "kind": "rule",
                "id": item["rule"],
                "evidence": item["evidence"],
                "recommendation": "candidate for demotion review; do not auto-disable",
            }
        )
    for item in zero_use_skills:
        downgrade_candidates.append(
            {
                "kind": "skill",
                "id": item["skill"],
                "evidence": item["evidence"],
                "recommendation": "candidate for on-demand doc; keep pending human review",
            }
        )

    # Follow-up actions --------------------------------------------------
    follow_up_actions: list[str] = []
    if no_data:
        follow_up_actions.append(
            "No event data in window: confirm logging is enabled before trusting risk sections."
        )
    if backlog:
        follow_up_actions.append(
            f"Triage {len(backlog)} unclassified / schema-gap candidate(s) so precision stays accurate."
        )
    if any(risk["at_risk"] for risk in precision_risks):
        follow_up_actions.append(
            "Review low-precision rules flagged under precision_risks before promotion."
        )
    if downgrade_candidates:
        follow_up_actions.append(
            f"Evaluate {len(downgrade_candidates)} downgrade candidate(s) against the U-32 constraint budget."
        )

    return {
        "schema_version": SCHEMA_VERSION,
        "window_days": args.days,
        "scope": args.scope,
        "generated_ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "data_sources": data_sources,
        "overview": overview,
        "rule_triggers": rule_triggers,
        "precision_risks": precision_risks,
        "unclassified_backlog": backlog,
        "idle_assets": {
            "zero_trigger_rules": zero_trigger_rules,
            "zero_use_skills": zero_use_skills,
        },
        "downgrade_candidates": downgrade_candidates,
        "follow_up_actions": follow_up_actions,
    }


# ---------------------------------------------------------------------------
# Markdown rendering (rendered from the schema, never a second data path)
# ---------------------------------------------------------------------------

def render_markdown(report: dict[str, Any]) -> str:
    lines: list[str] = []
    overview = report["overview"]
    lines.append("# VibeGuard Health Report")
    lines.append("")
    lines.append(f"- Scope: **{report['scope']}**")
    lines.append(f"- Window: last **{report['window_days']}** days")
    lines.append(f"- Generated: {report['generated_ts']}")
    sources = ", ".join(f"{s['name']}={s['status']}" for s in report["data_sources"])
    lines.append(f"- Data sources: {sources}")
    lines.append("")

    lines.append("## Overview")
    if overview["no_data"]:
        lines.append("")
        lines.append("**NO DATA** — no events in this scope/window. Risk sections below are empty by absence, not by health.")
    else:
        lines.append("")
        lines.append(f"- Total triggers: {overview['total_triggers']}")
        dist = overview["decision_distribution"]
        if dist:
            dist_str = ", ".join(f"{k}={dist[k]}" for k in sorted(dist))
            lines.append(f"- Decision distribution: {dist_str}")
        else:
            lines.append("- Decision distribution: (none)")
        lines.append(f"- Attention rate: {overview['attention_rate']}")
        lines.append(f"- Range: {overview['first_ts']} .. {overview['last_ts']}")
    lines.append("")

    lines.append("## Rule Trigger Distribution")
    lines.append("")
    if report["rule_triggers"]:
        lines.append("| Rule | Triggers |")
        lines.append("| --- | --- |")
        for item in report["rule_triggers"]:
            lines.append(f"| {item['rule']} | {item['count']} |")
    else:
        lines.append("(no rule-id triggers in window)")
    lines.append("")

    lines.append("## Precision Risk")
    lines.append("")
    if report["precision_risks"]:
        lines.append("| Rule | Stage | Precision | TP | FP | Samples | Last FP |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- |")
        for risk in report["precision_risks"]:
            prec = risk["precision"]
            prec_str = f"{prec * 100:.1f}%" if isinstance(prec, (int, float)) else "N/A"
            flag = " ⚠" if risk["at_risk"] else ""
            lines.append(
                f"| {risk['rule']}{flag} | {risk['stage']} | {prec_str} | "
                f"{risk['tp']} | {risk['fp']} | {risk['samples']} | {risk['last_fp_ts'] or '-'} |"
            )
    else:
        lines.append("(no precision data)")
    lines.append("")

    lines.append("### Unclassified Backlog / Schema Gap")
    lines.append("")
    if report["unclassified_backlog"]:
        for item in report["unclassified_backlog"]:
            rule = item.get("rule", "(no rule id)")
            lines.append(f"- line {item['line']}: {item['reason']} — rule={rule}")
    else:
        lines.append("(none)")
    lines.append("")

    lines.append("## Idle Assets")
    lines.append("")
    idle = report["idle_assets"]
    lines.append(f"- Zero-trigger rules ({len(idle['zero_trigger_rules'])}):")
    for item in idle["zero_trigger_rules"]:
        lines.append(f"  - {item['rule']} ({item['stage']}) — {item['evidence']}")
    lines.append(f"- Zero-use skills ({len(idle['zero_use_skills'])}):")
    for item in idle["zero_use_skills"]:
        lines.append(f"  - {item['skill']} — {item['evidence']}")
    lines.append("")

    lines.append("## Downgrade Candidates")
    lines.append("")
    if report["downgrade_candidates"]:
        for item in report["downgrade_candidates"]:
            lines.append(f"- [{item['kind']}] {item['id']}: {item['evidence']} — {item['recommendation']}")
    else:
        lines.append("(none)")
    lines.append("")

    lines.append("## Follow-up Actions")
    lines.append("")
    if report["follow_up_actions"]:
        for action in report["follow_up_actions"]:
            lines.append(f"- {action}")
    else:
        lines.append("(none)")
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="VibeGuard weekly health report — aggregate observe / precision / adoption data",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--days", type=int, default=30, help="window size in days (default: 30)")
    p.add_argument(
        "--scope",
        choices=["project", "global"],
        default="project",
        help="event log scope (default: project)",
    )
    p.add_argument("--project", metavar="PATH_OR_HASH", help="project reference for observe")
    p.add_argument("--log-file", metavar="PATH", help="explicit event log path")
    p.add_argument(
        "--format",
        choices=["markdown", "json"],
        default="markdown",
        help="output format (default: markdown)",
    )
    p.add_argument("--output", metavar="PATH", help="write to PATH instead of stdout")
    p.add_argument(
        "--triage-file",
        metavar="PATH",
        default=str(DEFAULT_TRIAGE_FILE),
        help=f"triage.jsonl path (default: {DEFAULT_TRIAGE_FILE})",
    )
    p.add_argument(
        "--scorecard-file",
        metavar="PATH",
        default=str(DEFAULT_SCORECARD_FILE),
        help=f"rule-scorecard.json path (default: {DEFAULT_SCORECARD_FILE})",
    )
    p.add_argument(
        "--adoptions-file",
        metavar="PATH",
        default=str(os.environ.get("VIBEGUARD_LEARN_ADOPTIONS_FILE", DEFAULT_ADOPTIONS_FILE)),
        help="learn-adoptions.jsonl path",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.days <= 0:
        print("[ERROR] --days must be a positive integer", file=sys.stderr)
        return 2
    try:
        report = build_report(args)
    except HealthReportError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    if args.format == "json":
        rendered = json.dumps(report, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    else:
        rendered = render_markdown(report) + "\n"

    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(rendered, encoding="utf-8")
        print(f"Wrote {args.format} report to {out_path}")
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
