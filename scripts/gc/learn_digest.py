#!/usr/bin/env python3
"""Generate weekly learning signals for gc-scheduled.sh."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone


log_dir = os.environ["_GC_LOG_DIR"]
vibeguard_dir = os.environ["_GC_VIBEGUARD_DIR"]
projects_dir = os.path.join(log_dir, "projects")
digest_file = os.path.join(log_dir, "learn-digest.jsonl")

if not os.path.isdir(projects_dir):
    print("No project data, skip")
    sys.exit(0)

now = datetime.now(timezone.utc)
learning_window_days = int(os.environ.get("_GC_LEARNING_WINDOW_DAYS", "7"))
cutoff_7d = (now - timedelta(days=learning_window_days)).strftime("%Y-%m-%dT")
signals_found = 0


def iter_text_lines_lossy(path):
    """Yield UTF-8 text lines without letting malformed bytes abort GC learning."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        yield from handle


def read_text_lossy(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def detect_guards(project_root):
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


def run_guard(script, project_root):
    """Run the guard script and return the number of violating lines."""
    try:
        result = subprocess.run(
            ["bash", script, project_root],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        output = result.stdout.strip()
        if not output:
            return 0, []
        violations = [line for line in output.split("\n") if line.startswith("[")]
        return len(violations), violations[:3]
    except (subprocess.TimeoutExpired, OSError):
        return 0, []


for proj in os.listdir(projects_dir):
    proj_dir = os.path.join(projects_dir, proj)
    if not os.path.isdir(proj_dir):
        continue

    events_file = os.path.join(proj_dir, "events.jsonl")
    project_root_file = os.path.join(proj_dir, ".project-root")

    signals = []
    session_set = set()
    has_recent_activity = False

    if os.path.exists(events_file):
        warn_reasons = Counter()
        block_reasons = Counter()
        edit_files = Counter()
        slow_count = 0

        for line in iter_text_lines_lossy(events_file):
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = evt.get("ts", "")
            if ts[:10] < cutoff_7d[:10]:
                continue
            has_recent_activity = True
            session_set.add(evt.get("session", ""))
            decision = evt.get("decision", "")
            reason = evt.get("reason", "")
            if decision == "warn" and reason:
                warn_reasons[reason] += 1
            elif decision == "block" and reason:
                block_reasons[reason] += 1
            if evt.get("tool") == "Edit" and evt.get("detail"):
                edit_files[evt["detail"].split()[-1]] += 1
            if evt.get("duration_ms", 0) > 5000:
                slow_count += 1

        for reason, count in warn_reasons.most_common(5):
            if count >= 10:
                signals.append(
                    {
                        "type": "repeated_warn",
                        "source": "events",
                        "reason": reason,
                        "count": count,
                        "sessions": len(session_set),
                    }
                )
        for reason, count in block_reasons.most_common(5):
            if count >= 5:
                signals.append(
                    {
                        "type": "chronic_block",
                        "source": "events",
                        "reason": reason,
                        "count": count,
                        "sessions": len(session_set),
                    }
                )
        for filepath, count in edit_files.most_common(5):
            if count >= 20:
                signals.append(
                    {
                        "type": "hot_files",
                        "source": "events",
                        "file": filepath,
                        "edits": count,
                        "sessions": len(session_set),
                    }
                )
        if slow_count >= 10:
            signals.append(
                {
                    "type": "slow_sessions",
                    "source": "events",
                    "count": slow_count,
                    "sessions": len(session_set),
                }
            )

        metrics_file = os.path.join(proj_dir, "session-metrics.jsonl")
        if os.path.exists(metrics_file):
            mid = (now - timedelta(days=3.5)).strftime("%Y-%m-%dT")
            early_warns, late_warns = 0, 0
            for ml in iter_text_lines_lossy(metrics_file):
                ml = ml.strip()
                if not ml:
                    continue
                try:
                    m = json.loads(ml)
                except json.JSONDecodeError:
                    continue
                mts = m.get("ts", "")
                if mts[:10] < cutoff_7d[:10]:
                    continue
                has_recent_activity = True
                w = m.get("decisions", {}).get("warn", 0)
                if mts < mid:
                    early_warns += w
                else:
                    late_warns += w
            if early_warns > 0 and late_warns > early_warns * 1.5:
                signals.append(
                    {
                        "type": "warn_escalation",
                        "source": "events",
                        "early": early_warns,
                        "late": late_warns,
                        "ratio": round(late_warns / max(early_warns, 1), 2),
                    }
                )

    if has_recent_activity and os.path.exists(project_root_file):
        project_root = read_text_lossy(project_root_file).strip()
        if os.path.isdir(project_root):
            guards = detect_guards(project_root)
            for guard_script, prefix in guards:
                vcount, examples = run_guard(guard_script, project_root)
                if vcount >= 5:
                    guard_name = os.path.basename(guard_script).replace("check_", "").replace(".sh", "")
                    signals.append(
                        {
                            "type": "linter_violations",
                            "source": "code_scan",
                            "guard": guard_name,
                            "count": vcount,
                            "examples": examples,
                        }
                    )

    if signals:
        signals_found += len(signals)
        entry = {
            "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "project": proj,
            "signals": signals,
            "recommendation": f"consider /vibeguard:learn for project {proj}",
        }
        if os.path.exists(project_root_file):
            entry["project_root"] = read_text_lossy(project_root_file).strip()
        with open(digest_file, "a", encoding="utf-8") as df:
            df.write(json.dumps(entry, ensure_ascii=False) + "\n")
        print(f" project {proj}: {len(signals)} learning signals")
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
