#!/usr/bin/env bash
# VibeGuard GC — Log Archiving
#
# events.jsonl Archives (gzip) monthly when threshold is exceeded, retaining the last 3 months.
#
# Usage:
# bash gc-logs.sh # Default 10MB threshold
# bash gc-logs.sh --threshold 5 # 5MB threshold
# bash gc-logs.sh --dry-run # Only report, not execute

set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

LOG_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
LOG_FILE="${LOG_DIR}/events.jsonl"
ARCHIVE_DIR="${LOG_DIR}/archive"
THRESHOLD_MB=10
DRY_RUN=false
RETAIN_MONTHS=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold) THRESHOLD_MB="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --retain) RETAIN_MONTHS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ ! -f "$LOG_FILE" ]]; then
  yellow "Log file does not exist: ${LOG_FILE}"
  exit 0
fi

FILE_SIZE_MB=$(du -m "$LOG_FILE" | cut -f1)
echo "Current log size: ${FILE_SIZE_MB}MB (Threshold: ${THRESHOLD_MB}MB)"

# Archive: Split and compress by month when threshold is exceeded
if [[ "$FILE_SIZE_MB" -ge "$THRESHOLD_MB" ]]; then
  mkdir -p "$ARCHIVE_DIR"

  #Group and archive by month
  python3 -c "
import json, sys, os
from collections import defaultdict

log_file = '${LOG_FILE}'
archive_dir = '${ARCHIVE_DIR}'
dry_run = ${DRY_RUN:+True} or False

months = defaultdict(list)
kept = []
cutoff_line = 0
total = 0

with open(log_file) as f:
    for line in f:
        total += 1
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
            ts = event.get('ts', '')
            month = ts[:7]  # YYYY-MM
            if month:
                months[month].append(line)
            else:
                kept.append(line)
        except json.JSONDecodeError:
            kept.append(line)

# Keep the current month’s data in the main file
sorted_months = sorted(months.keys())
if sorted_months:
    current_month = sorted_months[-1]
    kept.extend(months.pop(current_month))

archived = 0
for month, lines in sorted(months.items()):
    archive_path = os.path.join(archive_dir, f'events-{month}.jsonl')
    if dry_run:
        print(f' [DRY-RUN] Archive {len(lines)} → {archive_path}')
    else:
        with open(archive_path, 'a') as af:
            af.write('\n'.join(lines) + '\n')
    archived += len(lines)

if not dry_run and archived > 0:
    with open(log_file, 'w') as f:
        f.write('\n'.join(kept) + '\n' if kept else '')
    os.chmod(log_file, 0o600)

print(f'Total {total} items, archive {archived} items, retain {len(kept)} items')
"

  # Compress archive file
  if [[ "$DRY_RUN" == "false" ]]; then
    for f in "${ARCHIVE_DIR}"/events-*.jsonl; do
      [[ -f "$f" ]] || continue
      gzip -f "$f" 2>/dev/null && green "Compressed: $(basename "$f").gz"
    done
  fi
else
  green "Log size does not exceed the threshold, no need to archive"
fi

# Clean up expired archives: delete archives that exceed RETAIN_MONTHS
if [[ -d "$ARCHIVE_DIR" ]]; then
  CUTOFF=$(date -v-${RETAIN_MONTHS}m +%Y-%m 2>/dev/null || date -d "${RETAIN_MONTHS} months ago" +%Y-%m 2>/dev/null || echo "")
  if [[ -n "$CUTOFF" ]]; then
    for f in "${ARCHIVE_DIR}"/events-*.jsonl.gz; do
      [[ -f "$f" ]] || continue
      MONTH=$(basename "$f" | sed 's/events-\(.*\)\.jsonl\.gz/\1/')
      if [[ "$MONTH" < "$CUTOFF" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          yellow " [DRY-RUN] Delete expired archives: $(basename "$f")"
        else
          rm "$f"
          yellow "Expired archive deleted: $(basename "$f")"
        fi
      fi
    done
  fi
fi

green "Log GC completed"
