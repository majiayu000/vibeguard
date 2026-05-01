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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/project_config.sh
source "${SCRIPT_DIR}/../lib/project_config.sh"

LOG_DIR="${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}"
LOG_FILE="${LOG_DIR}/events.jsonl"
ARCHIVE_DIR="${LOG_DIR}/archive"
THRESHOLD_MB="$(vg_config_positive_int VIBEGUARD_GC_LOG_THRESHOLD_MB gc.log_threshold_mb 10)"
DRY_RUN=false
RETAIN_MONTHS="$(vg_config_positive_int VIBEGUARD_GC_ARCHIVE_RETAIN_MONTHS gc.archive_retain_months 3)"

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
  _GC_LOG_FILE="$LOG_FILE" \
  _GC_ARCHIVE_DIR="$ARCHIVE_DIR" \
  _GC_DRY_RUN="$([[ "$DRY_RUN" == "true" ]] && echo 1 || echo 0)" \
  python3 <<'PYEOF'
import fcntl
import json
import os
import tempfile
import time
from collections import defaultdict

log_file = os.environ['_GC_LOG_FILE']
archive_dir = os.environ['_GC_ARCHIVE_DIR']
dry_run = os.environ['_GC_DRY_RUN'] == '1'
lock_dir = log_file + '.lock.d'
lock_file = log_file + '.lock'

months = defaultdict(list)
kept = []
total = 0

def acquire_lock():
    deadline = time.time() + 10
    while True:
        try:
            os.mkdir(lock_dir)
            break
        except FileExistsError:
            if time.time() >= deadline:
                raise TimeoutError(f'timed out waiting for log lock: {lock_dir}')
            time.sleep(0.02)

    fd = os.open(lock_file, os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd

def release_lock(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
        try:
            os.rmdir(lock_dir)
        except FileNotFoundError:
            pass

def atomic_replace_log(lines):
    parent = os.path.dirname(log_file) or '.'
    fd, tmp = tempfile.mkstemp(prefix='.events.', suffix='.tmp', dir=parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            if lines:
                f.write('\n'.join(lines) + '\n')
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, log_file)
        dir_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise

lock_fd = acquire_lock()
try:
    with open(log_file, encoding='utf-8') as f:
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

    # Keep the current month's data in the main file
    sorted_months = sorted(months.keys())
    if sorted_months:
        current_month = sorted_months[-1]
        kept.extend(months.pop(current_month))

    archived = 0
    for month, lines in sorted(months.items()):
        archive_path = os.path.join(archive_dir, f'events-{month}.jsonl')
        if dry_run:
            print(f' [DRY-RUN] Archive {len(lines)} -> {archive_path}')
        else:
            with open(archive_path, 'a', encoding='utf-8') as af:
                af.write('\n'.join(lines) + '\n')
                af.flush()
                os.fsync(af.fileno())
        archived += len(lines)

    if not dry_run and archived > 0:
        atomic_replace_log(kept)

    print(f'Total {total} items, archive {archived} items, retain {len(kept)} items')
finally:
    release_lock(lock_fd)
PYEOF

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
