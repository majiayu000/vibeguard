#!/usr/bin/env python3
"""Analyze VibeGuard learning signals for preview and scheduled GC."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


DEFAULT_GUARD_TIMEOUT_SECONDS = 30.0
DEFAULT_LEARNING_WINDOW_DAYS = 7
DEFAULT_PREVIEW_BUDGET_MS = 5000


@dataclass
class AnalyzerOptions:
    code_scan: bool
    guard_timeout_seconds: float
    max_events: int | None


class RunState:
    def __init__(self, budget_ms: int | None) -> None:
        self.start = time.monotonic()
        self.budget_ms = budget_ms
        self.partial = False
        self.truncated_reason: str | None = None

    def mark_partial(self, reason: str) -> None:
        if not self.partial:
            self.partial = True
            self.truncated_reason = reason

    def budget_exceeded(self) -> bool:
        if self.budget_ms is None:
            return False
        elapsed_ms = (time.monotonic() - self.start) * 1000
        if elapsed_ms >= self.budget_ms:
            self.mark_partial("budget_ms")
            return True
        return False

    def remaining_seconds(self, default_timeout: float) -> float:
        if self.budget_ms is None:
            return default_timeout
        elapsed_ms = (time.monotonic() - self.start) * 1000
        remaining_ms = max(self.budget_ms - elapsed_ms, 0)
        return max(min(default_timeout, remaining_ms / 1000), 0.001)


def iter_text_lines_lossy(path: str):
    """Yield UTF-8 text lines without letting malformed bytes abort learning."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        yield from handle


def read_text_lossy(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def default_log_dir() -> str:
    return os.environ.get("_GC_LOG_DIR") or os.environ.get("VIBEGUARD_LOG_DIR") or os.path.join(
        str(Path.home()), ".vibeguard"
    )


def default_vibeguard_dir() -> str:
    return (
        os.environ.get("_GC_VIBEGUARD_DIR")
        or os.environ.get("VIBEGUARD_REPO_DIR")
        or str(Path(__file__).resolve().parents[2])
    )


def sha256_short(value: str, length: int = 8) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:length]


def resolve_path_lossy(path: str) -> str:
    return str(Path(path).expanduser().resolve(strict=False))


def git_root(path: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", path, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def roots_match(left: str, right: str) -> bool:
    return resolve_path_lossy(left) == resolve_path_lossy(right)


def project_id_from_hash(project_hash: str) -> str:
    normalized = project_hash.strip()
    if not normalized:
        raise ValueError("--project-hash cannot be empty")
    return normalized[:8]


def read_project_root(project_dir: str) -> str | None:
    root_file = os.path.join(project_dir, ".project-root")
    if not os.path.exists(root_file):
        return None
    root = read_text_lossy(root_file).strip()
    return root or None


def resolve_current_project(log_dir: str, project_root: str | None, project_hash: str | None) -> dict[str, Any]:
    projects_dir = os.path.join(log_dir, "projects")
    if project_hash:
        project_id = project_id_from_hash(project_hash)
        project_dir = os.path.join(projects_dir, project_id)
        return {
            "project": project_id,
            "project_dir": project_dir,
            "project_root": read_project_root(project_dir) or project_root,
        }

    root = project_root or git_root(os.getcwd()) or os.getcwd()
    root = resolve_path_lossy(root)
    if os.path.isdir(projects_dir):
        for name in sorted(os.listdir(projects_dir)):
            candidate_dir = os.path.join(projects_dir, name)
            if not os.path.isdir(candidate_dir):
                continue
            mapped_root = read_project_root(candidate_dir)
            if mapped_root and roots_match(mapped_root, root):
                return {
                    "project": name,
                    "project_dir": candidate_dir,
                    "project_root": resolve_path_lossy(mapped_root),
                }

    project_id = sha256_short(root)
    return {
        "project": project_id,
        "project_dir": os.path.join(projects_dir, project_id),
        "project_root": root,
    }


def resolve_global_projects(log_dir: str, max_projects: int | None, state: RunState) -> list[dict[str, Any]]:
    projects_dir = os.path.join(log_dir, "projects")
    if not os.path.isdir(projects_dir):
        return []

    names = [name for name in sorted(os.listdir(projects_dir)) if os.path.isdir(os.path.join(projects_dir, name))]
    if max_projects is not None and len(names) > max_projects:
        names = names[:max_projects]
        state.mark_partial("max_projects")

    projects = []
    for name in names:
        project_dir = os.path.join(projects_dir, name)
        projects.append(
            {
                "project": name,
                "project_dir": project_dir,
                "project_root": read_project_root(project_dir),
            }
        )
    return projects


def detect_guards(project_root: str, vibeguard_dir: str) -> list[tuple[str, str]]:
    """Return [(guard_script, rule_id_prefix)] list."""
    guards = []
    guards_dir = os.path.join(vibeguard_dir, "guards")
    if not os.path.isdir(guards_dir):
        return guards
    slop = os.path.join(guards_dir, "universal", "check_code_slop.sh")
    if os.path.exists(slop):
        guards.append((slop, "SLOP"))
    if os.path.exists(os.path.join(project_root, "Cargo.toml")):
        rust_dir = os.path.join(guards_dir, "rust")
        for filename in os.listdir(rust_dir) if os.path.isdir(rust_dir) else []:
            if filename.startswith("check_") and filename.endswith(".sh"):
                guards.append((os.path.join(rust_dir, filename), "RS"))
    if os.path.exists(os.path.join(project_root, "tsconfig.json")) or os.path.exists(
        os.path.join(project_root, "package.json")
    ):
        ts_dir = os.path.join(guards_dir, "typescript")
        for filename in os.listdir(ts_dir) if os.path.isdir(ts_dir) else []:
            if filename.startswith("check_") and filename.endswith(".sh"):
                guards.append((os.path.join(ts_dir, filename), "TS"))
    if os.path.exists(os.path.join(project_root, "go.mod")):
        go_dir = os.path.join(guards_dir, "go")
        for filename in os.listdir(go_dir) if os.path.isdir(go_dir) else []:
            if filename.startswith("check_") and filename.endswith(".sh"):
                guards.append((os.path.join(go_dir, filename), "GO"))
    return guards


def run_guard(script: str, project_root: str, timeout_seconds: float) -> tuple[int, list[str], str | None]:
    """Run a guard script and return (violation_count, examples, diagnostic_error)."""
    try:
        result = subprocess.run(
            ["bash", script, project_root],
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return 0, [], "timeout"
    except OSError as exc:
        return 0, [], f"os_error:{exc.__class__.__name__}"

    output = result.stdout.strip()
    if not output:
        return 0, [], None
    violations = [line for line in output.split("\n") if line.startswith("[")]
    return len(violations), violations[:3], None


def extract_edit_path(detail: str) -> str:
    parts = detail.strip().split()
    if not parts:
        return ""
    return parts[-1]


def event_edit_path(event: dict[str, Any]) -> str:
    path = event.get("path")
    if isinstance(path, str) and path.strip():
        return path
    detail = event.get("detail")
    if isinstance(detail, str):
        return extract_edit_path(detail)
    return ""


def classify_project_path(raw_path: str, project_root: str | None) -> tuple[str, str, str]:
    """Return (path_relation, normalized_path, display_path)."""
    if not raw_path:
        return "unknown", "", ""
    if not project_root:
        return "unknown", raw_path, raw_path

    root = resolve_path_lossy(project_root)
    candidate = Path(raw_path).expanduser()
    if not candidate.is_absolute():
        candidate = Path(root) / candidate
    normalized = str(candidate.resolve(strict=False))
    try:
        relation = "in_project" if os.path.commonpath([root, normalized]) == root else "external"
    except ValueError:
        relation = "external"
    if relation == "in_project":
        display = os.path.relpath(normalized, root)
    else:
        display = normalized
    return relation, normalized, display


def session_count(sessions: set[str]) -> int:
    return len({session for session in sessions if session})


def signal_identity(project_id: str, signal: dict[str, Any]) -> str:
    if signal["type"] in {"repeated_warn", "chronic_block"}:
        normalized_key = f'reason:{signal.get("reason", "")}'
    elif signal["type"] == "hot_files":
        normalized_key = f'path:{signal.get("path", signal.get("file", ""))}'
    elif signal["type"] == "linter_violations":
        normalized_key = f'guard:{signal.get("guard", "")}'
    else:
        normalized_key = signal["type"]

    signal["normalized_key"] = normalized_key
    encoded = json.dumps(
        {
            "schema_version": 1,
            "project": project_id,
            "type": signal["type"],
            "normalized_key": normalized_key,
        },
        sort_keys=True,
        ensure_ascii=False,
    )
    return "learn:" + sha256_short(encoded, 16)


def make_signal(project_id: str, signal: dict[str, Any], sessions: set[str]) -> dict[str, Any]:
    affected_sessions = session_count(sessions)
    signal["affected_sessions"] = affected_sessions
    signal["sessions"] = affected_sessions
    signal["signal_id"] = signal_identity(project_id, signal)
    return signal


def recent_prefix(now: datetime, learning_window_days: int) -> str:
    return (now - timedelta(days=learning_window_days)).strftime("%Y-%m-%dT")


def analyze_events(
    result: dict[str, Any],
    project_id: str,
    project_root: str | None,
    cutoff: str,
    options: AnalyzerOptions,
    state: RunState,
) -> set[str]:
    events_file = result["events_file"]
    project_sessions: set[str] = set()
    if not os.path.exists(events_file):
        return project_sessions

    warn_reasons: Counter[str] = Counter()
    warn_sessions: defaultdict[str, set[str]] = defaultdict(set)
    block_reasons: Counter[str] = Counter()
    block_sessions: defaultdict[str, set[str]] = defaultdict(set)
    edit_files: Counter[str] = Counter()
    edit_sessions: defaultdict[str, set[str]] = defaultdict(set)
    edit_paths: dict[str, str] = {}
    external_edit_files: Counter[str] = Counter()
    external_edit_sessions: defaultdict[str, set[str]] = defaultdict(set)
    malformed_events = 0
    slow_count = 0
    slow_sessions: set[str] = set()

    for line in iter_text_lines_lossy(events_file):
        if state.budget_exceeded():
            break
        if options.max_events is not None and result["events_read"] >= options.max_events:
            state.mark_partial("max_events")
            break
        result["events_read"] += 1
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            malformed_events += 1
            continue
        timestamp = event.get("ts", "")
        if timestamp[:10] < cutoff[:10]:
            continue
        result["has_recent_activity"] = True
        session = event.get("session", "")
        project_sessions.add(session)
        decision = event.get("decision", "")
        reason = event.get("reason", "")
        if decision == "warn" and reason:
            warn_reasons[reason] += 1
            warn_sessions[reason].add(session)
        elif decision == "block" and reason:
            block_reasons[reason] += 1
            block_sessions[reason].add(session)
        if event.get("tool") == "Edit":
            raw_path = event_edit_path(event)
            relation, normalized, display = classify_project_path(raw_path, project_root)
            if relation == "in_project":
                edit_files[display] += 1
                edit_sessions[display].add(session)
                edit_paths[display] = normalized
            elif relation == "external":
                external_edit_files[normalized] += 1
                external_edit_sessions[normalized].add(session)
        if event.get("duration_ms", 0) > 5000:
            slow_count += 1
            slow_sessions.add(session)

    for reason, count in warn_reasons.most_common(5):
        if count >= 10:
            result["signals"].append(
                make_signal(
                    project_id,
                    {
                        "type": "repeated_warn",
                        "source": "events",
                        "reason": reason,
                        "count": count,
                    },
                    warn_sessions[reason],
                )
            )
    for reason, count in block_reasons.most_common(5):
        if count >= 5:
            result["signals"].append(
                make_signal(
                    project_id,
                    {
                        "type": "chronic_block",
                        "source": "events",
                        "reason": reason,
                        "count": count,
                    },
                    block_sessions[reason],
                )
            )
    for filepath, count in edit_files.most_common(5):
        if count >= 20:
            result["signals"].append(
                make_signal(
                    project_id,
                    {
                        "type": "hot_files",
                        "source": "events",
                        "file": filepath,
                        "path": edit_paths[filepath],
                        "path_relation": "in_project",
                        "edits": count,
                    },
                    edit_sessions[filepath],
                )
            )
    for filepath, count in external_edit_files.most_common(5):
        result["diagnostics"].append(
            {
                "type": "edit_path",
                "path": filepath,
                "path_relation": "external",
                "classification": "noise",
                "events": count,
                "affected_sessions": session_count(external_edit_sessions[filepath]),
            }
        )
    if slow_count >= 10:
        result["signals"].append(
            make_signal(
                project_id,
                {
                    "type": "slow_sessions",
                    "source": "events",
                    "count": slow_count,
                },
                slow_sessions,
            )
        )
    if malformed_events:
        result["diagnostics"].append(
            {
                "type": "malformed_events",
                "classification": "noise",
                "events": malformed_events,
            }
        )
    return project_sessions


def analyze_metrics(
    result: dict[str, Any],
    project_id: str,
    now: datetime,
    learning_window_days: int,
    state: RunState,
) -> None:
    metrics_file = os.path.join(result["project_dir"], "session-metrics.jsonl")
    if not os.path.exists(metrics_file) or state.budget_exceeded():
        return

    cutoff = recent_prefix(now, learning_window_days)
    mid = (now - timedelta(days=learning_window_days / 2)).strftime("%Y-%m-%dT")
    early_warns = 0
    late_warns = 0
    escalation_sessions: set[str] = set()
    malformed_metrics = 0

    for line in iter_text_lines_lossy(metrics_file):
        if state.budget_exceeded():
            break
        line = line.strip()
        if not line:
            continue
        try:
            metric = json.loads(line)
        except json.JSONDecodeError:
            malformed_metrics += 1
            continue
        timestamp = metric.get("ts", "")
        if timestamp[:10] < cutoff[:10]:
            continue
        result["has_recent_activity"] = True
        warns = metric.get("decisions", {}).get("warn", 0)
        if warns:
            escalation_sessions.add(metric.get("session", ""))
        if timestamp < mid:
            early_warns += warns
        else:
            late_warns += warns

    if early_warns > 0 and late_warns > early_warns * 1.5:
        result["signals"].append(
            make_signal(
                project_id,
                {
                    "type": "warn_escalation",
                    "source": "events",
                    "early": early_warns,
                    "late": late_warns,
                    "ratio": round(late_warns / max(early_warns, 1), 2),
                },
                escalation_sessions,
            )
        )
    if malformed_metrics:
        result["diagnostics"].append(
            {
                "type": "malformed_metrics",
                "classification": "noise",
                "events": malformed_metrics,
            }
        )


def analyze_code_scan(
    result: dict[str, Any],
    project_id: str,
    project_sessions: set[str],
    vibeguard_dir: str,
    options: AnalyzerOptions,
    state: RunState,
) -> None:
    project_root = result.get("project_root")
    if not (
        options.code_scan
        and result["has_recent_activity"]
        and project_root
        and os.path.isdir(project_root)
        and not state.budget_exceeded()
    ):
        return

    for guard_script, _prefix in detect_guards(project_root, vibeguard_dir):
        if state.budget_exceeded():
            break
        timeout_seconds = state.remaining_seconds(options.guard_timeout_seconds)
        violation_count, examples, diagnostic_error = run_guard(guard_script, project_root, timeout_seconds)
        guard_name = os.path.basename(guard_script).replace("check_", "").replace(".sh", "")
        if diagnostic_error:
            if diagnostic_error == "timeout":
                state.mark_partial(f"guard_timeout:{guard_name}")
            result["diagnostics"].append(
                {
                    "type": "code_scan",
                    "guard": guard_name,
                    "classification": "truncated" if diagnostic_error == "timeout" else "error",
                    "error": diagnostic_error,
                }
            )
            break
        if violation_count >= 5:
            result["signals"].append(
                make_signal(
                    project_id,
                    {
                        "type": "linter_violations",
                        "source": "code_scan",
                        "guard": guard_name,
                        "count": violation_count,
                        "examples": examples,
                    },
                    project_sessions,
                )
            )


def analyze_project(
    project: dict[str, Any],
    now: datetime,
    learning_window_days: int,
    vibeguard_dir: str,
    options: AnalyzerOptions,
    state: RunState,
) -> dict[str, Any]:
    project_id = project["project"]
    project_dir = project["project_dir"]
    project_root = project.get("project_root")
    result: dict[str, Any] = {
        "project": project_id,
        "project_dir": project_dir,
        "project_root": project_root,
        "events_file": os.path.join(project_dir, "events.jsonl"),
        "signals": [],
        "diagnostics": [],
        "events_read": 0,
        "has_recent_activity": False,
    }

    cutoff = recent_prefix(now, learning_window_days)
    project_sessions = analyze_events(result, project_id, project_root, cutoff, options, state)
    analyze_metrics(result, project_id, now, learning_window_days, state)
    analyze_code_scan(result, project_id, project_sessions, vibeguard_dir, options, state)
    return result


def analyze_projects(
    projects: list[dict[str, Any]],
    now: datetime,
    learning_window_days: int,
    vibeguard_dir: str,
    options: AnalyzerOptions,
    state: RunState,
) -> list[dict[str, Any]]:
    results = []
    for project in projects:
        if state.budget_exceeded():
            break
        results.append(analyze_project(project, now, learning_window_days, vibeguard_dir, options, state))
    return results


def flattened(results: list[dict[str, Any]], key: str) -> list[dict[str, Any]]:
    items = []
    for result in results:
        for item in result.get(key, []):
            with_project = dict(item)
            with_project["project"] = result["project"]
            items.append(with_project)
    return items


def build_report(
    args: argparse.Namespace,
    now: datetime,
    projects: list[dict[str, Any]],
    results: list[dict[str, Any]],
    state: RunState,
) -> dict[str, Any]:
    return {
        "command": "learn",
        "mode": "scheduled" if args.scheduled else "preview",
        "scope": args.scope,
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "partial": state.partial,
        "truncated_reason": state.truncated_reason,
        "wrote_output": bool(args.output and (not args.scheduled or not args.dry_run)),
        "project_count": len(projects),
        "projects": results,
        "signals": flattened(results, "signals"),
        "diagnostics": flattened(results, "diagnostics"),
    }


def digest_entries(report: dict[str, Any]) -> list[dict[str, Any]]:
    entries = []
    for project in report["projects"]:
        signals = project.get("signals", [])
        if not signals:
            continue
        entry = {
            "ts": report["generated_at"],
            "project": project["project"],
            "signals": signals,
            "recommendation": f"consider /vibeguard:learn for project {project['project']}",
        }
        if project.get("project_root"):
            entry["project_root"] = project["project_root"]
        entries.append(entry)
    return entries


def render_json(report: dict[str, Any]) -> str:
    return json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2) + "\n"


def render_text(report: dict[str, Any]) -> str:
    lines = []
    entries = digest_entries(report)
    if report["project_count"] == 0:
        return "No project data, skip\n"
    signals_found = 0
    for entry in entries:
        signals = entry["signals"]
        signals_found += len(signals)
        lines.append(f" project {entry['project']}: {len(signals)} learning signals")
        for signal in signals:
            if signal["type"] == "linter_violations":
                lines.append(f' - [code scan] {signal["guard"]}: {signal["count"]} violations')
            else:
                detail = signal.get("reason", signal.get("file", ""))
                count = signal.get("count", signal.get("edits", ""))
                lines.append(f' - [Event Log] {signal["type"]}: {detail} ({count})')
    if signals_found == 0:
        lines.append("No need to learn signals")
    elif report["mode"] == "scheduled" and report.get("wrote_output"):
        lines.append(f" A total of {signals_found} signals have been written to learn-digest.jsonl")
    else:
        lines.append(f" A total of {signals_found} signals were found")
    if report["partial"]:
        lines.append(f"Partial result: {report['truncated_reason']}")
    return "\n".join(lines) + "\n"


def write_output(path: str, report: dict[str, Any], output_format: str, scheduled: bool) -> None:
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if scheduled:
        with output_path.open("a", encoding="utf-8") as handle:
            for entry in digest_entries(report):
                handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
        return
    content = render_json(report) if output_format == "json" else render_text(report)
    output_path.write_text(content, encoding="utf-8")


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("value must be >= 0")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Preview or generate VibeGuard learning signals.")
    parser.add_argument("--scope", choices=["current", "global"], default="current")
    parser.add_argument("--project-root", help="Project root used to resolve the current project log.")
    parser.add_argument("--project-hash", help="Explicit project hash/directory under the VibeGuard log directory.")
    parser.add_argument("--dry-run", action="store_true", help="Do not write digest or output files.")
    parser.add_argument("--format", choices=["json", "text"], default="json")
    parser.add_argument("--output", help="Write preview output, or append scheduled digest JSONL.")
    parser.add_argument("--max-projects", type=positive_int, help="Maximum number of projects for global analysis.")
    parser.add_argument("--max-events", type=positive_int, help="Maximum number of events to read per project.")
    parser.add_argument("--budget-ms", type=positive_int, help="Wall-clock analysis budget in milliseconds.")
    parser.add_argument("--guard-timeout", type=float, default=DEFAULT_GUARD_TIMEOUT_SECONDS)
    parser.add_argument("--no-code-scan", action="store_true", help="Disable guard/code scanning.")
    parser.add_argument("--scheduled", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument(
        "--learning-window-days",
        type=positive_int,
        default=int(os.environ.get("_GC_LEARNING_WINDOW_DAYS", str(DEFAULT_LEARNING_WINDOW_DAYS))),
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    log_dir = default_log_dir()
    vibeguard_dir = default_vibeguard_dir()
    now = datetime.now(timezone.utc)
    budget_ms = args.budget_ms
    if budget_ms is None and args.scope == "current" and not args.scheduled:
        budget_ms = DEFAULT_PREVIEW_BUDGET_MS
    state = RunState(budget_ms)
    code_scan = args.scheduled and not args.no_code_scan
    options = AnalyzerOptions(
        code_scan=code_scan,
        guard_timeout_seconds=args.guard_timeout,
        max_events=args.max_events,
    )

    if args.scope == "current":
        projects = [resolve_current_project(log_dir, args.project_root, args.project_hash)]
    else:
        projects = resolve_global_projects(log_dir, args.max_projects, state)

    results = analyze_projects(projects, now, args.learning_window_days, vibeguard_dir, options, state)
    report = build_report(args, now, projects, results, state)
    if args.output and (not args.scheduled or not args.dry_run):
        write_output(args.output, report, args.format, args.scheduled)
    sys.stdout.write(render_json(report) if args.format == "json" else render_text(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
