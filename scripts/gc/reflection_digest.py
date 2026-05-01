#!/usr/bin/env python3
"""Generate weekly session reflection report for gc-scheduled.sh."""

from __future__ import annotations

import json
import os
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone


log_dir = os.environ["_GC_LOG_DIR"]
projects_dir = os.path.join(log_dir, "projects")
output_file = os.environ["_GC_REFLECTION_FILE"]

if not os.path.isdir(projects_dir):
    print("No project data, skip")
    sys.exit(0)

now = datetime.now(timezone.utc)
cutoff_7d = (now - timedelta(days=7)).strftime("%Y-%m-%dT")

all_sessions = []
project_names = {}
for proj in os.listdir(projects_dir):
    proj_dir = os.path.join(projects_dir, proj)
    if not os.path.isdir(proj_dir):
        continue
    root_file = os.path.join(proj_dir, ".project-root")
    if os.path.exists(root_file):
        project_names[proj] = open(root_file, encoding="utf-8").read().strip().split("/")[-1]
    else:
        project_names[proj] = proj

    metrics_file = os.path.join(proj_dir, "session-metrics.jsonl")
    if not os.path.exists(metrics_file):
        continue
    with open(metrics_file, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                metric = json.loads(line)
                if metric.get("ts", "")[:10] >= cutoff_7d[:10]:
                    metric["_project"] = proj
                    all_sessions.append(metric)
            except json.JSONDecodeError:
                continue

if not all_sessions:
    print("No session data in the past 7 days, skip")
    sys.exit(0)

total_sessions = len(all_sessions)
total_events = sum(session.get("event_count", 0) for session in all_sessions)

decision_totals = Counter()
for session in all_sessions:
    for decision, count in session.get("decisions", {}).items():
        decision_totals[decision] += count

sessions_with_corrections = 0
all_correction_signals = Counter()
for session in all_sessions:
    signals = session.get("correction_signals", [])
    if signals:
        sessions_with_corrections += 1
        for signal in signals:
            if "repeated revision" in signal:
                all_correction_signals["File repeatedly corrected"] += 1
            elif "high friction" in signal:
                all_correction_signals["High Friction Session"] += 1
            elif "correction detection" in signal:
                all_correction_signals["Real-time correction trigger"] += 1
            elif "upgrade warning" in signal:
                all_correction_signals["Upgrade warning"] += 1

hook_totals = Counter()
for session in all_sessions:
    for hook, count in session.get("hooks", {}).items():
        hook_totals[hook] += count

high_friction = [session for session in all_sessions if session.get("warn_ratio", 0) > 0.4]

file_edits = Counter()
for session in all_sessions:
    for file_path, count in session.get("top_edited_files", {}).items():
        if file_path:
            file_edits[file_path] += count

report = []
report.append("# VibeGuard Weekly Reflection Report")
report.append("")
report.append(f'> Generation time: {now.strftime("%Y-%m-%d %H:%M UTC")}')
report.append(">Coverage: Last 7 days")
report.append("")
report.append("## overview")
report.append("")
report.append(f"- Number of sessions: {total_sessions}")
report.append(f"-Total number of events: {total_events}")
report.append(
    f'- pass: {decision_totals.get("pass", 0)} | warn: {decision_totals.get("warn", 0)} | '
    f'block: {decision_totals.get("block", 0)} | escalate: {decision_totals.get("escalate", 0)}'
)
total_decisions = sum(decision_totals.values())
overall_warn_rate = (
    decision_totals.get("warn", 0)
    + decision_totals.get("block", 0)
    + decision_totals.get("escalate", 0)
) / max(total_decisions, 1)
report.append(f"- overall friction rate: {overall_warn_rate:.0%}")
report.append("")

if sessions_with_corrections > 0 or high_friction:
    report.append("##Correction signal")
    report.append("")
    report.append(f"- Sessions with correction signals: {sessions_with_corrections}/{total_sessions}")
    report.append(f"- High friction session (>40% warn): {len(high_friction)}")
    if all_correction_signals:
        report.append("- signal type:")
        for signal, count in all_correction_signals.most_common():
            report.append(f" - {signal}: {count} times")
    report.append("")

report.append("## Top trigger Hook")
report.append("")
for hook, count in hook_totals.most_common(5):
    report.append(f"- {hook}: {count} times")
report.append("")

if file_edits:
    report.append("## Hotspot files (high-frequency editing across sessions)")
    report.append("")
    for file_path, count in file_edits.most_common(5):
        basename = os.path.basename(file_path)
        report.append(f"- {basename}: {count} edits")
    report.append("")

suggestions = []
if overall_warn_rate > 0.3:
    suggestions.append(
        "The overall friction rate is high → Check the reason for top warn and consider adding new rules or enhancing Hook prompts"
    )
if sessions_with_corrections > total_sessions * 0.3:
    suggestions.append("More than 30% of sessions have correction signals → run /vibeguard:learn batch extraction mode")
top_hook = hook_totals.most_common(1)
if top_hook and top_hook[0][1] > total_events * 0.3:
    suggestions.append(f"{top_hook[0][0]} is triggered too frequently → check whether there are false positives or the rules are too strict")
if file_edits:
    top_file = file_edits.most_common(1)[0]
    if top_file[1] > 30:
        suggestions.append(f"{os.path.basename(top_file[0])} Edited {top_file[1]} times → Consider splitting components or reviewing the architecture")

report.append("## Improvement suggestions")
report.append("")
if suggestions:
    for i, suggestion in enumerate(suggestions, 1):
        report.append(f"{i}. {suggestion}")
else:
    report.append("There is no significant improvement signal this week, the system is running normally.")
report.append("")

with open(output_file, "w", encoding="utf-8") as f:
    f.write("\n".join(report))

print(f" Generate reflection report: {output_file}")
print(f" Sessions: {total_sessions}, Events: {total_events}, Friction rate: {overall_warn_rate:.0%}")
if suggestions:
    for suggestion in suggestions:
        print(f"    - {suggestion}")
