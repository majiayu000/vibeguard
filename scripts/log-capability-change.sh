#!/usr/bin/env bash
# VibeGuard ability evolution log
#
# Scan the git log for commits involving guards/, rules/, skills/,
# Output the formatted ability evolution timeline.
#
# Usage:
# bash log-capability-change.sh # Full history
# bash log-capability-change.sh --since 2026-02-01 # From the specified date
# bash log-capability-change.sh --type guard # Guard changes only
# bash log-capability-change.sh --json # JSON format output

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SINCE=""
TYPE_FILTER=""
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --type) TYPE_FILTER="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) shift ;;
  esac
done

cd "$REPO_DIR"

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Not in git repository"
  exit 1
fi

# Build git log parameters
GIT_ARGS=("log" "--pretty=format:%H|%aI|%s" "--name-only" "--diff-filter=ACDMR")
if [[ -n "$SINCE" ]]; then
  GIT_ARGS+=("--since=$SINCE")
fi
GIT_ARGS+=("--" "guards/" "rules/" "hooks/" "skills/")

# Run git log and parse
GIT_OUTPUT=$(git "${GIT_ARGS[@]}" 2>/dev/null || true)

VG_GIT_OUTPUT="$GIT_OUTPUT" VG_TYPE_FILTER="$TYPE_FILTER" VG_JSON="$JSON_OUTPUT" python3 -c '
import sys, os, json
from collections import defaultdict

type_filter = os.environ.get("VG_TYPE_FILTER", "")
json_output = os.environ.get("VG_JSON", "false") == "true"

# Read git log output from environment variables
raw = os.environ.get("VG_GIT_OUTPUT", "")
if not raw.strip():
    print("No capability change record found.")
    sys.exit(0)

# Parse git log output
entries = []
current = None
for line in raw.split("\n"):
    line = line.strip()
    if not line:
        continue
    if "|" in line and line.count("|") >= 2:
        # New commit line
        parts = line.split("|", 2)
        if len(parts) == 3:
            if current:
                entries.append(current)
            current = {
                "hash": parts[0][:8],
                "date": parts[1][:10],
                "message": parts[2],
                "files": [],
            }
    elif current is not None:
        current["files"].append(line)

if current:
    entries.append(current)

# Category file changes
def classify(path):
    if path.startswith("guards/"):
        return "guard"
    elif path.startswith("rules/"):
        return "rule"
    elif path.startswith("hooks/"):
        return "hook"
    elif path.startswith("skills/"):
        return "skill"
    return "other"

# Rich entry information
for entry in entries:
    types = set()
    for f in entry["files"]:
        t = classify(f)
        if t != "other":
            types.add(t)
    entry["types"] = sorted(types)

# filter
if type_filter:
    entries = [e for e in entries if type_filter in e["types"]]

if not entries:
    print(f"No ability change record of type \"{type_filter}\" found.")
    sys.exit(0)

if json_output:
    print(json.dumps(entries, ensure_ascii=False, indent=2))
    sys.exit(0)

# Format output
print(f"""
VibeGuard capability evolution timeline
{"=" * 50}
Total {len(entries)} changes
""")

#Group by month
by_month = defaultdict(list)
for entry in entries:
    month = entry["date"][:7]
    by_month[month].append(entry)

type_icons = {"guard": "🛡", "rule": "📏", "hook": "🪝", "skill": "🎯"}

for month in sorted(by_month.keys(), reverse=True):
    month_entries = by_month[month]
    print(f"--- {month} ({len(month_entries)} changes) ---")
    for entry in month_entries:
        e_date = entry["date"]
        e_msg = entry["message"]
        icons = " ".join(type_icons.get(t, "?") for t in entry["types"])
        print(f"  {e_date}  {icons}  {e_msg}")
        # List changed files (up to 5)
        e_files = entry["files"]
        for ef in e_files[:5]:
            cat = classify(ef)
            print(f"    {cat:>5}: {ef}")
        extra = len(e_files) - 5
        if extra > 0:
            print(f" ... +{extra} files")
    print()

# Statistical summary
type_counts = defaultdict(int)
for entry in entries:
    for t in entry["types"]:
        type_counts[t] += 1

print("Change type distribution:")
for t in sorted(type_counts.keys()):
    icon = type_icons.get(t, "?")
    print(f" {icon} {t}: {type_counts[t]} times")
print()
'
