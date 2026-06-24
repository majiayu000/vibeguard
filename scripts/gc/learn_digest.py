#!/usr/bin/env python3
"""Generate weekly learning signals for gc-scheduled.sh and preview them."""

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


DEFAULT_GUARD_TIMEOUT_SECONDS = 30.0
DEFAULT_PREVIEW_BUDGET_MS = 2000
DEFAULT_LEARNING_WINDOW_DAYS = 7


@dataclass
class AnalyzerOptions:
    code_scan: bool = True
    filter_external_hot_files: bool = False
    guard_timeout_seconds: float = DEFAULT_GUARD_TIMEOUT_SECONDS
    max_events: int | None = None


class RunState:
    def __init__(self, budget_ms: int | None = None) -> None:
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
    """Yield UTF-8 text lines without letting malformed bytes abort GC learning."""
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


def sha256_short(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:8]


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
    except (subprocess.TimeoutExpired, OSError):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def roots_match(left: str, right: str) -> bool:
    if left == right:
        return True
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
    return read_text_lossy(root_file).strip()


def resolve_current_project(log_dir: str, project_root: str | None, project_hash: str | None) -> dict:
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
                    "project_root": mapped_root,
                }

    project_id = sha256_short(root)
    return {
        "project": project_id,
        "project_dir": os.path.join(projects_dir, project_id),
        "project_root": root,
    }


def resolve_global_projects(log_dir: str, max_projects: int | None, state: RunState) -> list[dict]:
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
        for f in os.listdir(rust_dir) if os.path.isdir(rust_dir) else []:
            if f.startswith("check_") and f.endswith(".sh"):
                guards.append((os.path.join(rust_dir, f), "RS"))
    if os.path.exists(os.path.join(project_root, "tsconfig.json")) or os.path.exists(
        os.path.join(project_root, "package.json")
    ):
        ts_dir = os.path.join(guards_dir, "typescript")
        for f in os.listdir(ts_dir) if os.path.isdir(ts_dir) else []:
            if f.startswith("check_") and f.endswith(".sh"):
                guards.append((os.path.join(ts_dir, f), "TS"))
    if os.path.exists(os.path.join(project_root, "go.mod")):
        go_dir = os.path.join(guards_dir, "go")
        for f in os.listdir(go_dir) if os.path.isdir(go_dir) else []:
            if f.startswith("check_") and f.endswith(".sh"):
                guards.append((os.path.join(go_dir, f), "GO"))
    return guards


def run_guard(script: str, project_root: str, timeout_seconds: float) -> tuple[int, list[str], str | None]:
    """Run the guard script and return (violation_count, examples, failure_reason)."""
    try:
        result = subprocess.run(
            ["bash", script, project_root],
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
        output = result.stdout.strip()
        if not output:
            return 0, [], None
        violations = [line for line in output.split("\n") if line.startswith("[")]
        return len(violations), violations[:3], None
    except subprocess.TimeoutExpired:
        return 0, [], "timeout"
    except OSError as exc:
        return 0, [], f"os_error:{exc.__class__.__name__}"


def extract_edit_path(detail: str) -> str:
    parts = detail.strip().split()
    if not parts:
        return ""
    return parts[-1]


def classify_project_path(raw_path: str, project_root: str | None) -> tuple[str, str, str]:
    """Return (relation, normalized_path, display_path)."""
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


def session_count(sessions) -> int:
    return len({session for session in sessions if session})


def add_signal_id(project_id: str, signal: dict) -> dict:
    stable = {
        key: value
        for key, value in signal.items()
        if key not in {
            "signal_id",
            "sessions",
            "affected_sessions",
            "examples",
            "count",
            "edits",
            "early",
            "late",
            "ratio",
        }
    }
    encoded = json.dumps({"project": project_id, "signal": stable}, sort_keys=True, ensure_ascii=False)
    signal["signal_id"] = "learn:" + hashlib.sha256(encoded.encode("utf-8")).hexdigest()[:16]
    return signal


def make_signal(project_id: str, signal: dict, sessions) -> dict:
    affected_sessions = session_count(sessions)
    signal["affected_sessions"] = affected_sessions
    signal["sessions"] = affected_sessions
    return add_signal_id(project_id, signal)


def analyze_project(
    project: dict,
    now: datetime,
    learning_window_days: int,
    vibeguard_dir: str,
    options: AnalyzerOptions,
    state: RunState,
) -> dict:
    project_id = project["project"]
    project_dir = project["project_dir"]
    project_root = project.get("project_root")
    events_file = os.path.join(project_dir, "events.jsonl")
    metrics_file = os.path.join(project_dir, "session-metrics.jsonl")
    cutoff = (now - timedelta(days=learning_window_days)).strftime("%Y-%m-%dT")

    result = {
        "project": project_id,
        "project_dir": project_dir,
        "project_root": project_root,
        "events_file": events_file,
        "signals": [],
        "diagnostics": [],
        "events_read": 0,
        "has_recent_activity": False,
    }

    project_sessions = set()

    if os.path.exists(events_file):
        warn_reasons = Counter()
        warn_sessions = defaultdict(set)
        block_reasons = Counter()
        block_sessions = defaultdict(set)
        edit_files = Counter()
        edit_sessions = defaultdict(set)
        external_edit_files = Counter()
        external_edit_sessions = defaultdict(set)
        slow_count = 0
        slow_sessions = set()

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
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = evt.get("ts", "")
            if ts[:10] < cutoff[:10]:
                continue
            result["has_recent_activity"] = True
            session = evt.get("session", "")
            project_sessions.add(session)
            decision = evt.get("decision", "")
            reason = evt.get("reason", "")
            if decision == "warn" and reason:
                warn_reasons[reason] += 1
                warn_sessions[reason].add(session)
            elif decision == "block" and reason:
                block_reasons[reason] += 1
                block_sessions[reason].add(session)
            if evt.get("tool") == "Edit" and evt.get("detail"):
                raw_path = extract_edit_path(evt["detail"])
                if options.filter_external_hot_files:
                    relation, normalized, display = classify_project_path(raw_path, project_root)
                    if relation == "in_project":
                        edit_files[display] += 1
                        edit_sessions[display].add(session)
                    elif relation == "external":
                        external_edit_files[normalized] += 1
                        external_edit_sessions[normalized].add(session)
                elif raw_path:
                    edit_files[raw_path] += 1
                    edit_sessions[raw_path].add(session)
            if evt.get("duration_ms", 0) > 5000:
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
                            "path_relation": "in_project" if options.filter_external_hot_files else "unknown",
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

    if os.path.exists(metrics_file) and not state.budget_exceeded():
        mid = (now - timedelta(days=learning_window_days / 2)).strftime("%Y-%m-%dT")
        early_warns, late_warns = 0, 0
        escalation_sessions = set()
        for ml in iter_text_lines_lossy(metrics_file):
            if state.budget_exceeded():
                break
            ml = ml.strip()
            if not ml:
                continue
            try:
                metric = json.loads(ml)
            except json.JSONDecodeError:
                continue
            mts = metric.get("ts", "")
            if mts[:10] < cutoff[:10]:
                continue
            result["has_recent_activity"] = True
            w = metric.get("decisions", {}).get("warn", 0)
            if w:
                escalation_sessions.add(metric.get("session", ""))
            if mts < mid:
                early_warns += w
            else:
                late_warns += w
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

    if (
        options.code_scan
        and result["has_recent_activity"]
        and project_root
        and os.path.isdir(project_root)
        and not state.budget_exceeded()
    ):
        guards = detect_guards(project_root, vibeguard_dir)
        for guard_script, _prefix in guards:
            if state.budget_exceeded():
                break
            timeout_seconds = state.remaining_seconds(options.guard_timeout_seconds)
            vcount, examples, guard_failure = run_guard(guard_script, project_root, timeout_seconds)
            guard_name = os.path.basename(guard_script).replace("check_", "").replace(".sh", "")
            if guard_failure == "timeout":
                reason = "budget_ms" if state.budget_exceeded() else f"guard_timeout:{guard_name}"
                state.mark_partial(reason)
                result["diagnostics"].append(
                    {
                        "type": "code_scan",
                        "guard": guard_name,
                        "classification": "truncated",
                        "truncated_reason": state.truncated_reason,
                    }
                )
                break
            if guard_failure:
                result["diagnostics"].append(
                    {
                        "type": "code_scan",
                        "guard": guard_name,
                        "classification": "runtime_health",
                        "error": guard_failure,
                    }
                )
                continue
            if vcount >= 5:
                result["signals"].append(
                    make_signal(
                        project_id,
                        {
                            "type": "linter_violations",
                            "source": "code_scan",
                            "guard": guard_name,
                            "count": vcount,
                            "examples": examples,
                        },
                        project_sessions,
                    )
                )

    return result


def analyze_projects(
    projects: list[dict],
    now: datetime,
    learning_window_days: int,
    vibeguard_dir: str,
    options: AnalyzerOptions,
    state: RunState,
) -> list[dict]:
    results = []
    for project in projects:
        if state.budget_exceeded():
            break
        results.append(analyze_project(project, now, learning_window_days, vibeguard_dir, options, state))
    return results


def scheduled_project_list(log_dir: str) -> list[dict]:
    projects_dir = os.path.join(log_dir, "projects")
    projects = []
    for proj in sorted(os.listdir(projects_dir)):
        proj_dir = os.path.join(projects_dir, proj)
        if not os.path.isdir(proj_dir):
            continue
        projects.append(
            {
                "project": proj,
                "project_dir": proj_dir,
                "project_root": read_project_root(proj_dir),
            }
        )
    return projects


def run_scheduled() -> int:
    log_dir = os.environ["_GC_LOG_DIR"]
    vibeguard_dir = os.environ["_GC_VIBEGUARD_DIR"]
    projects_dir = os.path.join(log_dir, "projects")
    digest_file = os.path.join(log_dir, "learn-digest.jsonl")

    if not os.path.isdir(projects_dir):
        print("No project data, skip")
        return 0

    now = datetime.now(timezone.utc)
    learning_window_days = int(os.environ.get("_GC_LEARNING_WINDOW_DAYS", str(DEFAULT_LEARNING_WINDOW_DAYS)))
    state = RunState()
    options = AnalyzerOptions(
        code_scan=True,
        filter_external_hot_files=False,
        guard_timeout_seconds=DEFAULT_GUARD_TIMEOUT_SECONDS,
    )
    results = analyze_projects(
        scheduled_project_list(log_dir),
        now,
        learning_window_days,
        vibeguard_dir,
        options,
        state,
    )

    signals_found = 0
    for result in results:
        signals = result["signals"]
        if not signals:
            continue
        signals_found += len(signals)
        entry = {
            "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "project": result["project"],
            "signals": signals,
            "recommendation": f"consider /vibeguard:learn for project {result['project']}",
        }
        if result.get("project_root"):
            entry["project_root"] = result["project_root"]
        with open(digest_file, "a", encoding="utf-8") as df:
            df.write(json.dumps(entry, ensure_ascii=False) + "\n")
        print(f" project {result['project']}: {len(signals)} learning signals")
        for signal in signals:
            if signal["type"] == "linter_violations":
                print(f' - [code scan] {signal["guard"]}: {signal["count"]} violations')
            else:
                detail = signal.get("reason", signal.get("file", ""))
                count = signal.get("count", signal.get("edits", ""))
                print(f' - [Event Log] {signal["type"]}: {detail} ({count})')

    if signals_found == 0:
        print("No need to learn signals")
    else:
        print(f" A total of {signals_found} signals have been written to learn-digest.jsonl")
    return 0


def build_learn_digest_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Preview or generate VibeGuard learning signals.")
    parser.add_argument("--scope", choices=["current", "global"], default="current")
    parser.add_argument("--project-root", help="Project root used to resolve the current project log.")
    parser.add_argument("--project-hash", help="Project hash used to resolve the current project log.")
    parser.add_argument("--dry-run", action="store_true", help="Preview only; accepted for compatibility.")
    parser.add_argument("--format", choices=["json", "text"], default="text")
    parser.add_argument("--output", help="Write preview output to this path instead of stdout.")
    parser.add_argument("--max-projects", type=int, help="Maximum project log directories to analyze.")
    parser.add_argument("--max-events", type=int, help="Maximum event rows to inspect per project.")
    parser.add_argument("--budget-ms", type=int, default=DEFAULT_PREVIEW_BUDGET_MS)
    parser.add_argument("--guard-timeout", type=float, default=DEFAULT_GUARD_TIMEOUT_SECONDS)
    parser.add_argument("--no-code-scan", action="store_true", help="Skip guard-based code scans.")
    parser.add_argument("--log-dir", help="VibeGuard log directory. Defaults to VIBEGUARD_LOG_DIR or ~/.vibeguard.")
    return parser


def format_text_preview(payload: dict) -> str:
    lines = []
    total_signals = sum(len(project["signals"]) for project in payload["projects"])
    if total_signals == 0:
        lines.append("No need to learn signals")
    for project in payload["projects"]:
        signals = project["signals"]
        if not signals:
            continue
        lines.append(f"project {project['project']}: {len(signals)} learning signals")
        for signal in signals:
            if signal["type"] == "linter_violations":
                lines.append(f' - [code scan] {signal["guard"]}: {signal["count"]} violations')
            else:
                detail = signal.get("reason", signal.get("file", ""))
                count = signal.get("count", signal.get("edits", ""))
                sessions = signal.get("affected_sessions", 0)
                lines.append(f' - [events] {signal["type"]}: {detail} ({count}, sessions {sessions})')
    if payload["partial"]:
        lines.append(f"Partial: {payload['truncated_reason']}")
    return "\n".join(lines) + "\n"


def write_output(payload: dict, output_format: str, output_path: str | None) -> None:
    if output_format == "json":
        text = json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    else:
        text = format_text_preview(payload)

    if output_path:
        with open(output_path, "w", encoding="utf-8") as handle:
            handle.write(text)
    else:
        print(text, end="")


def run_preview(args: argparse.Namespace) -> int:
    log_dir = args.log_dir or default_log_dir()
    vibeguard_dir = default_vibeguard_dir()
    now = datetime.now(timezone.utc)
    learning_window_days = int(os.environ.get("_GC_LEARNING_WINDOW_DAYS", str(DEFAULT_LEARNING_WINDOW_DAYS)))
    state = RunState(args.budget_ms)
    options = AnalyzerOptions(
        code_scan=not args.no_code_scan,
        filter_external_hot_files=args.scope == "current",
        guard_timeout_seconds=args.guard_timeout,
        max_events=args.max_events,
    )

    if args.scope == "current":
        projects = [resolve_current_project(log_dir, args.project_root, args.project_hash)]
    else:
        projects = resolve_global_projects(log_dir, args.max_projects, state)

    results = analyze_projects(projects, now, learning_window_days, vibeguard_dir, options, state)
    payload = {
        "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "scope": args.scope,
        "log_dir": log_dir,
        "dry_run": True,
        "partial": state.partial,
        "truncated_reason": state.truncated_reason,
        "projects": results,
    }
    write_output(payload, args.format, args.output)
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not argv and "_GC_LOG_DIR" in os.environ and "_GC_VIBEGUARD_DIR" in os.environ:
        return run_scheduled()
    parser = build_learn_digest_parser()
    args = parser.parse_args(argv)
    return run_preview(args)


if __name__ == "__main__":
    raise SystemExit(main())
