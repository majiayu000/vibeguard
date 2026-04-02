#!/usr/bin/env bash
# VibeGuard quality level automatic scoring
#
# Calculate the quality grade (A/B/C/D) from events.jsonl, output the score and recommended GC frequency.
#
# Scoring formula:
#   grade = security × 0.4 + stability × 0.3 + coverage × 0.2 + performance × 0.1
# Grade: A(≥90) B(70-89) C(50-69) D(<50)
# GC frequency: A=7 days B=3 days C=1 day D=real time
#
# Usage:
# bash quality-grader.sh # Analyze the last 30 days
# bash quality-grader.sh 7 # Analyze the last 7 days
# bash quality-grader.sh all # All history
# bash quality-grader.sh --json # JSON format output

set -euo pipefail

DAYS="30"
JSON_OUTPUT=false
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=true ;;
    all|[0-9]*) DAYS="$arg" ;;
  esac
done

LOG_FILE="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}/events.jsonl"

if [[ ! -f "$LOG_FILE" ]]; then
  echo "No log data. Hooks will be automatically logged to $LOG_FILE after being triggered"
  exit 0
fi

GUARDS_DIR="${REPO_DIR}/guards"
RULES_DIR="${REPO_DIR}/rules"
NATIVE_RULES_DIR="${HOME}/.claude/rules/vibeguard"

VG_DAYS="$DAYS" VG_LOG_FILE="$LOG_FILE" VG_GUARDS_DIR="$GUARDS_DIR" \
  VG_RULES_DIR="$RULES_DIR" VG_NATIVE_RULES_DIR="$NATIVE_RULES_DIR" \
  VG_JSON="$JSON_OUTPUT" python3 -c '
import json, sys, os, glob
from datetime import datetime, timezone, timedelta
from collections import Counter

days = os.environ.get("VG_DAYS", "30")
log_file = os.environ.get("VG_LOG_FILE", "")
guards_dir = os.environ.get("VG_GUARDS_DIR", "")
rules_dir = os.environ.get("VG_RULES_DIR", "")
native_rules_dir = os.environ.get("VG_NATIVE_RULES_DIR", "")
json_output = os.environ.get("VG_JSON", "false") == "true"

#Read events
events = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue

if not events:
    print("No log data.")
    sys.exit(0)

# Time filter
if days != "all":
    cutoff = datetime.now(timezone.utc) - timedelta(days=int(days))
    cutoff_str = cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")
    events = [e for e in events if e.get("ts", "") >= cutoff_str]

if not events:
    print(f"There is no log data in the last {days} days.")
    sys.exit(0)

total = len(events)
by_decision = Counter(e.get("decision", "unknown") for e in events)

blocks = by_decision.get("block", 0)
warns = by_decision.get("warn", 0)
passes = by_decision.get("pass", 0)

# --- Indicator calculation ---

# security: block The lower the interception rate, the better (indicating that the code quality is high and serious interceptions are rarely triggered)
# Calculation method: 100 - (block / total * 100)
security = max(0, 100 - (blocks / total * 100)) if total > 0 else 100

# stability: The higher the pass rate, the better
stability = (passes / total * 100) if total > 0 else 100

# coverage: Proportion of rules covered by guard scripts
rule_ids = set()
for md_file in glob.glob(os.path.join(rules_dir, "*.md")):
    with open(md_file) as f:
        for line in f:
            # Extract RS-XX, GO-XX, TS-XX, PY-XX, U-XX, SEC-XX formats
            import re
            for m in re.finditer(r"\b(RS|GO|TS|PY|U|SEC)-\d+\b", line):
                rule_ids.add(m.group())

guard_ids = set()
for guard_file in glob.glob(os.path.join(guards_dir, "**/*"), recursive=True):
    if not os.path.isfile(guard_file):
        continue
    try:
        with open(guard_file) as f:
            content = f.read()
            import re
            for m in re.finditer(r"\b(RS|GO|TS|PY|U|SEC)-\d+\b", content):
                guard_ids.add(m.group())
    except (UnicodeDecodeError, PermissionError):
        continue

implemented = rule_ids & guard_ids
coverage_mechanical = (len(implemented) / len(rule_ids) * 100) if rule_ids else 0

# AI visible coverage: rule ID appears in ~/.claude/rules/vibeguard/
ai_visible_ids = set()
if native_rules_dir and os.path.isdir(native_rules_dir):
    for nr_file in glob.glob(os.path.join(native_rules_dir, "**/*.md"), recursive=True):
        try:
            with open(nr_file) as f:
                for line in f:
                    import re
                    for m in re.finditer(r"\b(RS|GO|TS|PY|U|SEC|TASTE)-[\w]+\b", line):
                        ai_visible_ids.add(m.group())
        except (UnicodeDecodeError, PermissionError):
            continue

ai_visible = rule_ids & ai_visible_ids
coverage_ai = (len(ai_visible) / len(rule_ids) * 100) if rule_ids else 0
dual_covered = implemented & ai_visible

# Comprehensive coverage: AI visible + mechanical force (union)
all_covered = implemented | ai_visible
coverage = (len(all_covered) / len(rule_ids) * 100) if rule_ids else 0

# performance: The lower the proportion of slow operations, the better (duration_ms > 5000)
events_with_duration = [e for e in events if "duration_ms" in e]
if events_with_duration:
    slow_ops = sum(1 for e in events_with_duration if e.get("duration_ms", 0) > 5000)
    performance = max(0, 100 - (slow_ops / len(events_with_duration) * 100))
else:
    performance = 100 # No time-consuming data, default full score

# --- Weighted Rating ---
grade_score = security * 0.4 + stability * 0.3 + coverage * 0.2 + performance * 0.1
grade_score = round(grade_score, 1)

if grade_score >= 90:
    grade = "A"
    gc_days = 7
elif grade_score >= 70:
    grade = "B"
    gc_days = 3
elif grade_score >= 50:
    grade = "C"
    gc_days = 1
else:
    grade = "D"
    gc_days = 0 # real-time

gc_freq = f"{gc_days} days" if gc_days > 0 else "real time"

if json_output:
    result = {
        "grade": grade,
        "score": grade_score,
        "gc_frequency_days": gc_days,
        "metrics": {
            "security": round(security, 1),
            "stability": round(stability, 1),
            "coverage": round(coverage, 1),
            "coverage_mechanical": round(coverage_mechanical, 1),
            "coverage_ai_visible": round(coverage_ai, 1),
            "performance": round(performance, 1),
        },
        "events_analyzed": total,
        "rules_total": len(rule_ids),
        "rules_implemented": len(implemented),
        "rules_ai_visible": len(ai_visible),
        "rules_dual_covered": len(dual_covered),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
else:
    period = "all history" if days == "all" else f"last {days} days"
    print(f"""
VibeGuard quality score ({period})
{"=" * 40}
Grade: {grade} ({grade_score} points)
Recommended GC frequency: {gc_freq}

Sub-indicators:
  Security (×0.4): {security:.1f} (block {blocks}/{total})
  Stability (×0.3): {stability:.1f} (pass {passes}/{total})
  Coverage (×0.2): {coverage:.1f} (combined {len(all_covered)}/{len(rule_ids)} rules)
    Mechanical enforcement: {coverage_mechanical:.1f} (guards/hooks {len(implemented)})
    AI visible: {coverage_ai:.1f} (~/.claude/rules/ {len(ai_visible)} items)
    Double coverage: {len(dual_covered)} items
  Performance (×0.1): {performance:.1f} ({slow_ops if events_with_duration else "N/A"}/{len(events_with_duration)} times)

Total number of events: {total}
Total number of rules: {len(rule_ids)} (Comprehensive coverage: {len(all_covered)}, Uncovered: {len(rule_ids - all_covered)})""")

    if rule_ids - all_covered:
        uncovered = sorted(rule_ids - all_covered)
        uncovered_str = ", ".join(uncovered[:10])
        extra = f" (+{len(uncovered)-10} items)" if len(uncovered) > 10 else ""
        print(f"Uncovered rule: {uncovered_str}{extra}")
    print()
'
