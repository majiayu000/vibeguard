#!/usr/bin/env python3
"""
VibeGuard Precision Tracker
============================
Reads data/triage.jsonl and data/rule-scorecard.json to:
  - Compute per-rule precision stats
  - Apply lifecycle transitions (experimental → warn → error, or → demoted)
  - Generate monthly/on-demand reports

Usage:
  python3 scripts/precision-tracker.py                  # print report
  python3 scripts/precision-tracker.py --update-scorecard  # recalculate + save scorecard
  python3 scripts/precision-tracker.py --rule RS-03     # report for one rule
  python3 scripts/precision-tracker.py --record tp RS-03 [--context "note"]
  python3 scripts/precision-tracker.py --record fp RS-03 [--context "note"]
  python3 scripts/precision-tracker.py --record acceptable RS-03 [--context "note"]

Lifecycle thresholds (borrowing from Semgrep Pro / Clippy categories):
  EXPERIMENTAL → WARN   : precision ≥ 70%  AND samples ≥ 20
  WARN         → ERROR  : precision ≥ 90%  AND samples ≥ 50  AND 30 days no FP
  WARN/ERROR   → DEMOTED: precision < 80%  (after ≥ 20 samples)
  DEMOTED      → DISABLED: manual only
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Generator

# ---------------------------------------------------------------------------
# Paths (relative to repo root, resolved from script location)
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_DIR = SCRIPT_DIR.parent
TRIAGE_FILE = REPO_DIR / "data" / "triage.jsonl"
SCORECARD_FILE = REPO_DIR / "data" / "rule-scorecard.json"

# ---------------------------------------------------------------------------
# Lifecycle thresholds
# ---------------------------------------------------------------------------
EXPERIMENTAL_TO_WARN_PRECISION = 0.70
EXPERIMENTAL_TO_WARN_SAMPLES = 20

WARN_TO_ERROR_PRECISION = 0.90
WARN_TO_ERROR_SAMPLES = 50
WARN_TO_ERROR_NO_FP_DAYS = 30

DEMOTION_PRECISION = 0.80
DEMOTION_MIN_SAMPLES = 20

VALID_VERDICTS = {"tp", "fp", "acceptable"}

# Severity × Confidence → stage mapping
# Used only as documentation; actual graduation is data-driven.
SEVERITY_CONFIDENCE_MATRIX = {
    ("high", "high"): "error",
    ("high", "medium"): "warn",
    ("high", "low"): "warn",
    ("medium", "high"): "warn",
    ("medium", "medium"): "warn",
    ("medium", "low"): "off",
    ("low", "high"): "warn",
    ("low", "medium"): "off",
    ("low", "low"): "off",
}


# ---------------------------------------------------------------------------
# File locking (Unix: fcntl; Windows: no-op — atomic os.replace still guards
# against truncated files, but concurrent lost-update is not prevented)
# ---------------------------------------------------------------------------

try:
    import fcntl as _fcntl

    @contextmanager
    def _scorecard_write_lock(scorecard_path: Path) -> Generator[None, None, None]:
        lock_path = scorecard_path.with_suffix(".lock")
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open("a") as lock_fh:
            _fcntl.flock(lock_fh, _fcntl.LOCK_EX)
            try:
                yield
            finally:
                _fcntl.flock(lock_fh, _fcntl.LOCK_UN)

except ImportError:
    @contextmanager
    def _scorecard_write_lock(scorecard_path: Path) -> Generator[None, None, None]:  # type: ignore[misc]
        yield


# ---------------------------------------------------------------------------
# Triage record validation
# ---------------------------------------------------------------------------

def _validate_triage_record(rec: Any, lineno: int) -> bool:
    """Return True if rec is a valid triage record; print [ERROR] and return False otherwise."""
    if not isinstance(rec, dict):
        print(
            f"[ERROR] triage.jsonl line {lineno}: expected object, got {type(rec).__name__}",
            file=sys.stderr,
        )
        return False
    rule = rec.get("rule")
    if not isinstance(rule, str) or not rule:
        print(
            f"[ERROR] triage.jsonl line {lineno}: 'rule' must be a non-empty string, got {rule!r}",
            file=sys.stderr,
        )
        return False
    verdict = rec.get("verdict")
    if verdict not in VALID_VERDICTS:
        print(
            f"[ERROR] triage.jsonl line {lineno}: 'verdict' must be one of {sorted(VALID_VERDICTS)}, got {verdict!r}",
            file=sys.stderr,
        )
        return False
    ts = rec.get("ts")
    if ts is not None and not isinstance(ts, str):
        print(
            f"[ERROR] triage.jsonl line {lineno}: 'ts' must be a string if present, got {type(ts).__name__}",
            file=sys.stderr,
        )
        return False
    return True


# ---------------------------------------------------------------------------
# Triage loading
# ---------------------------------------------------------------------------

def load_triage(path: Path) -> list[dict[str, Any]]:
    """Load triage.jsonl; skip comment/blank lines and reject malformed records."""
    records: list[dict[str, Any]] = []
    if not path.exists():
        return records
    with path.open(encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as exc:
                print(f"[WARN] triage.jsonl line {lineno}: {exc}", file=sys.stderr)
                continue
            if _validate_triage_record(rec, lineno):
                records.append(rec)
    return records


# ---------------------------------------------------------------------------
# Scorecard loading / saving
# ---------------------------------------------------------------------------

def load_scorecard(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"rules": {}}
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def save_scorecard(scorecard: dict[str, Any], path: Path) -> None:
    """Write scorecard atomically: temp file in same dir + os.replace()."""
    scorecard["_updated_ts"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    content = json.dumps(scorecard, indent=2, ensure_ascii=False) + "\n"
    dir_path = path.parent
    dir_path.mkdir(parents=True, exist_ok=True)
    fd, tmp_path_str = tempfile.mkstemp(dir=dir_path, prefix=".scorecard-", suffix=".tmp")
    tmp_path = Path(tmp_path_str)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.replace(tmp_path, path)
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Stats computation
# ---------------------------------------------------------------------------

def compute_rule_stats(
    triage_records: list[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    """Aggregate triage records into per-rule stats."""
    stats: dict[str, dict[str, Any]] = {}

    for rec in triage_records:
        rule = rec.get("rule", "UNKNOWN")
        verdict = rec.get("verdict", "")
        ts = rec.get("ts", "")

        if rule not in stats:
            stats[rule] = {"tp": 0, "fp": 0, "acceptable": 0, "last_fp_ts": None}

        if verdict == "tp":
            stats[rule]["tp"] += 1
        elif verdict == "fp":
            stats[rule]["fp"] += 1
            if ts and (stats[rule]["last_fp_ts"] is None or ts > stats[rule]["last_fp_ts"]):
                stats[rule]["last_fp_ts"] = ts
        elif verdict == "acceptable":
            stats[rule]["acceptable"] += 1

    return stats


def precision_of(tp: int, fp: int) -> float | None:
    """TP / (TP + FP).  Returns None when no positive predictions exist."""
    denom = tp + fp
    return tp / denom if denom > 0 else None


# ---------------------------------------------------------------------------
# Lifecycle transition
# ---------------------------------------------------------------------------

def days_since(ts_str: str | None) -> float | None:
    """Return days elapsed since ISO-8601 timestamp, or None if ts is None."""
    if not ts_str:
        return None
    try:
        dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - dt).total_seconds() / 86400
    except ValueError:
        return None


def next_stage(rule_entry: dict[str, Any]) -> str | None:
    """
    Compute target stage based on current stats.
    Returns new stage string if a transition should occur, else None.
    """
    stage = rule_entry.get("stage", "experimental")
    tp = rule_entry.get("tp", 0)
    fp = rule_entry.get("fp", 0)
    acceptable = rule_entry.get("acceptable", 0)
    samples = tp + fp + acceptable
    prec = precision_of(tp, fp)

    # Demotion takes priority: if we have enough data and precision is poor
    if samples >= DEMOTION_MIN_SAMPLES and prec is not None and prec < DEMOTION_PRECISION:
        if stage not in ("demoted", "disabled"):
            return "demoted"

    if stage == "experimental":
        if (
            prec is not None
            and prec >= EXPERIMENTAL_TO_WARN_PRECISION
            and samples >= EXPERIMENTAL_TO_WARN_SAMPLES
        ):
            return "warn"

    elif stage == "warn":
        if prec is not None and prec >= WARN_TO_ERROR_PRECISION and samples >= WARN_TO_ERROR_SAMPLES:
            last_fp_ts = rule_entry.get("last_fp_ts")
            days = days_since(last_fp_ts)
            # No FP ever, or last FP was > 30 days ago
            if last_fp_ts is None or (days is not None and days >= WARN_TO_ERROR_NO_FP_DAYS):
                return "error"

    return None


# ---------------------------------------------------------------------------
# Scorecard update
# ---------------------------------------------------------------------------

def update_scorecard(
    scorecard: dict[str, Any],
    triage_records: list[dict[str, Any]],
) -> tuple[dict[str, Any], list[str]]:
    """
    Recompute stats from triage records, apply lifecycle transitions.

    Rules present in scorecard but absent from triage have their counters
    reset to zero so that the scorecard stays consistent with triage truth
    (e.g. after a triage window rotation or manual cleanup).

    Returns (updated_scorecard, list of transition messages).
    """
    stats = compute_rule_stats(triage_records)
    transitions: list[str] = []

    rules = scorecard.setdefault("rules", {})

    # Update stats for rules present in triage
    for rule, s in stats.items():
        if rule not in rules:
            rules[rule] = {
                "stage": "experimental",
                "precision": None,
                "samples": 0,
                "tp": 0,
                "fp": 0,
                "acceptable": 0,
                "last_fp_ts": None,
                "stage_entered_ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "notes": "",
            }
        entry = rules[rule]
        entry["tp"] = s["tp"]
        entry["fp"] = s["fp"]
        entry["acceptable"] = s["acceptable"]
        entry["samples"] = s["tp"] + s["fp"] + s["acceptable"]
        entry["last_fp_ts"] = s["last_fp_ts"]
        prec = precision_of(s["tp"], s["fp"])
        entry["precision"] = round(prec, 4) if prec is not None else None

    # Reset stats for rules no longer present in triage (window rotation /
    # manual cleanup).  Stage and notes are preserved so the history is
    # visible, but counters reflect the current triage truth.
    for rule, entry in rules.items():
        if rule not in stats:
            entry["tp"] = 0
            entry["fp"] = 0
            entry["acceptable"] = 0
            entry["samples"] = 0
            entry["last_fp_ts"] = None
            entry["precision"] = None

    # Apply lifecycle transitions for all rules
    for rule, entry in rules.items():
        new_stage = next_stage(entry)
        if new_stage is not None:
            old_stage = entry["stage"]
            entry["stage"] = new_stage
            entry["stage_entered_ts"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            transitions.append(f"{rule}: {old_stage} → {new_stage}")

    return scorecard, transitions


# ---------------------------------------------------------------------------
# Report rendering
# ---------------------------------------------------------------------------

STAGE_SYMBOL = {
    "experimental": "🧪",
    "warn": "⚠️ ",
    "error": "🔴",
    "demoted": "⬇️ ",
    "disabled": "⏸️ ",
}


def render_report(scorecard: dict[str, Any], rule_filter: str | None = None) -> str:
    lines: list[str] = []
    lines.append("VibeGuard Rule Precision Scorecard")
    lines.append("=" * 60)
    updated = scorecard.get("_updated_ts", "unknown")
    lines.append(f"Updated: {updated}")
    lines.append("")

    rules = scorecard.get("rules", {})
    if rule_filter:
        rules = {k: v for k, v in rules.items() if k == rule_filter}

    if not rules:
        lines.append("(no rules)")
        return "\n".join(lines)

    # Header
    lines.append(
        f"{'Rule':<14} {'Stage':<14} {'Prec':>6} {'TP':>4} {'FP':>4} {'Acc':>4} {'Samples':>7}  Notes"
    )
    lines.append("-" * 80)

    for rule in sorted(rules.keys()):
        entry = rules[rule]
        stage = entry.get("stage", "?")
        prec = entry.get("precision")
        tp = entry.get("tp", 0)
        fp = entry.get("fp", 0)
        acceptable = entry.get("acceptable", 0)
        samples = entry.get("samples", 0)
        notes = entry.get("notes", "")[:40]
        symbol = STAGE_SYMBOL.get(stage, "  ")
        prec_str = f"{prec * 100:.1f}%" if prec is not None else "  N/A"
        lines.append(
            f"{rule:<14} {symbol}{stage:<12} {prec_str:>6} {tp:>4} {fp:>4} {acceptable:>4} {samples:>7}  {notes}"
        )

    lines.append("")
    lines.append("Lifecycle thresholds:")
    lines.append(
        f"  experimental → warn : precision ≥ {EXPERIMENTAL_TO_WARN_PRECISION*100:.0f}%  AND samples ≥ {EXPERIMENTAL_TO_WARN_SAMPLES}"
    )
    lines.append(
        f"  warn         → error: precision ≥ {WARN_TO_ERROR_PRECISION*100:.0f}%  AND samples ≥ {WARN_TO_ERROR_SAMPLES}  AND {WARN_TO_ERROR_NO_FP_DAYS}d no FP"
    )
    lines.append(
        f"  any          → demoted: precision < {DEMOTION_PRECISION*100:.0f}%  after ≥ {DEMOTION_MIN_SAMPLES} samples"
    )
    lines.append("")
    lines.append("Record feedback:")
    lines.append(
        "  python3 scripts/precision-tracker.py --record tp|fp|acceptable RULE-ID [--context NOTE]"
    )

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Record a verdict
# ---------------------------------------------------------------------------

def record_verdict(
    rule: str,
    verdict: str,
    context: str | None,
    triage_path: Path,
) -> None:
    if verdict not in VALID_VERDICTS:
        print(f"[ERROR] verdict must be tp, fp, or acceptable; got: {verdict}", file=sys.stderr)
        sys.exit(1)

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    session = os.environ.get("VIBEGUARD_SESSION_ID", "")
    rec: dict[str, Any] = {"ts": ts, "rule": rule, "verdict": verdict}
    if context:
        rec["context"] = context
    if session:
        rec["session"] = session

    with triage_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")

    print(f"Recorded {verdict} for {rule} at {ts}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="VibeGuard precision tracker — manage rule lifecycle from triage feedback",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--rule", metavar="RULE", help="filter report to a single rule")
    p.add_argument(
        "--update-scorecard",
        action="store_true",
        help="recompute stats from triage.jsonl and save rule-scorecard.json",
    )
    p.add_argument(
        "--record",
        nargs=2,
        metavar=("VERDICT", "RULE"),
        help="append a triage verdict (tp|fp|acceptable) for RULE",
    )
    p.add_argument("--context", metavar="NOTE", help="optional note for --record")
    p.add_argument(
        "--triage-file",
        metavar="PATH",
        default=str(TRIAGE_FILE),
        help=f"path to triage.jsonl (default: {TRIAGE_FILE})",
    )
    p.add_argument(
        "--scorecard-file",
        metavar="PATH",
        default=str(SCORECARD_FILE),
        help=f"path to rule-scorecard.json (default: {SCORECARD_FILE})",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    triage_path = Path(args.triage_file)
    scorecard_path = Path(args.scorecard_file)

    # --record verdict rule
    if args.record:
        verdict, rule = args.record
        with _scorecard_write_lock(scorecard_path):
            record_verdict(rule, verdict, args.context, triage_path)
            triage = load_triage(triage_path)
            scorecard = load_scorecard(scorecard_path)
            scorecard, transitions = update_scorecard(scorecard, triage)
            save_scorecard(scorecard, scorecard_path)
        if transitions:
            print("Lifecycle transitions:")
            for t in transitions:
                print(f"  {t}")
        return 0

    # --update-scorecard
    if args.update_scorecard:
        with _scorecard_write_lock(scorecard_path):
            triage = load_triage(triage_path)
            scorecard = load_scorecard(scorecard_path)
            scorecard, transitions = update_scorecard(scorecard, triage)
            save_scorecard(scorecard, scorecard_path)
        if transitions:
            print("Lifecycle transitions:")
            for t in transitions:
                print(f"  {t}")
        else:
            print("No lifecycle transitions.")
        print(f"Scorecard saved to {scorecard_path}")

    # Always print report
    scorecard = load_scorecard(scorecard_path)
    print(render_report(scorecard, rule_filter=args.rule))
    return 0


if __name__ == "__main__":
    sys.exit(main())
