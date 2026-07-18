#!/usr/bin/env bash
# VibeGuard GC — Log Archiving
#
# events.jsonl / codex-wrapper.jsonl archive (gzip) monthly when threshold is
# exceeded, retaining the last 3 months. The current month is additionally
# capped by line count so heavy-usage months cannot grow unbounded.
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
WRAPPER_LOG_FILE="${LOG_DIR}/codex-wrapper.jsonl"
ARCHIVE_DIR="${LOG_DIR}/archive"
THRESHOLD_MB="$(vg_config_positive_int VIBEGUARD_GC_LOG_THRESHOLD_MB gc.log_threshold_mb 10)"
DRY_RUN=false
RETAIN_MONTHS="$(vg_config_positive_int VIBEGUARD_GC_ARCHIVE_RETAIN_MONTHS gc.archive_retain_months 3)"
# Must stay below THRESHOLD_MB or the post-GC size re-check keeps failing.
CURRENT_MONTH_MAX_KB="$(vg_config_positive_int VIBEGUARD_GC_CURRENT_MONTH_MAX_KB gc.current_month_max_kb 8192)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold) THRESHOLD_MB="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --retain) RETAIN_MONTHS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

gc_one_log_file() {
  local log_file="$1"
  local archive_dir="$2"
  local label="$3"
  local prefix="${4:-events}"
  local file_size_mb

  file_size_mb=$(du -m "$log_file" | cut -f1)
  echo "Processing ${label}: ${log_file}"
  echo "Current log size: ${file_size_mb}MB (Threshold: ${THRESHOLD_MB}MB)"

  # Archive: split and compress by month when threshold is exceeded.
  if [[ "$file_size_mb" -ge "$THRESHOLD_MB" ]]; then
    mkdir -p "$archive_dir"

    _GC_LOG_FILE="$log_file" \
    _GC_ARCHIVE_DIR="$archive_dir" \
    _GC_ARCHIVE_PREFIX="$prefix" \
    _GC_CURRENT_MONTH_MAX_KB="$CURRENT_MONTH_MAX_KB" \
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
prefix = os.environ.get('_GC_ARCHIVE_PREFIX', 'events')
max_current_bytes = int(os.environ.get('_GC_CURRENT_MONTH_MAX_KB', '0') or '0') * 1024
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

run_stamp = time.strftime('%Y%m%dT%H%M%S')

def archive_target(month):
    # A compressed archive for this month may already exist from a previous
    # run; appending to a fresh plain file and re-running `gzip -f` would
    # silently replace it. Use a run-stamped name in that case.
    path = os.path.join(archive_dir, f'{prefix}-{month}.jsonl')
    if os.path.exists(path + '.gz'):
        path = os.path.join(archive_dir, f'{prefix}-{month}-{run_stamp}.jsonl')
    return path

def append_archive(path, lines):
    with open(path, 'a', encoding='utf-8') as af:
        af.write('\n'.join(lines) + '\n')
        af.flush()
        os.fsync(af.fileno())

lock_fd = acquire_lock()
try:
    with open(log_file, encoding='utf-8', errors='replace') as f:
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

    # Keep the current month's data in the main file, capped by byte budget so
    # a heavy month cannot keep the main file above the size threshold until
    # month rollover. Newest lines are kept first.
    current_month = None
    current_lines = []
    sorted_months = sorted(months.keys())
    if sorted_months:
        current_month = sorted_months[-1]
        current_lines = months.pop(current_month)

    overflow = []
    if max_current_bytes > 0:
        budget = max_current_bytes
        keep_from = len(current_lines)
        for idx in range(len(current_lines) - 1, -1, -1):
            budget -= len(current_lines[idx].encode('utf-8')) + 1
            if budget < 0:
                break
            keep_from = idx
        overflow = current_lines[:keep_from]
        current_lines = current_lines[keep_from:]
    kept.extend(current_lines)

    archived = 0
    for month, lines in sorted(months.items()):
        archive_path = archive_target(month)
        if dry_run:
            print(f' [DRY-RUN] Archive {len(lines)} -> {archive_path}')
        else:
            append_archive(archive_path, lines)
        archived += len(lines)

    if overflow:
        overflow_path = os.path.join(
            archive_dir, f'{prefix}-{current_month}-{run_stamp}.jsonl')
        if dry_run:
            print(f' [DRY-RUN] Archive current-month overflow {len(overflow)} -> {overflow_path}')
        else:
            append_archive(overflow_path, overflow)
        archived += len(overflow)

    if not dry_run and archived > 0:
        atomic_replace_log(kept)

    print(f'Total {total} items, archive {archived} items, retain {len(kept)} items')
finally:
    release_lock(lock_fd)
PYEOF

    # Compress archive files for this log target.
    if [[ "$DRY_RUN" == "false" ]]; then
      for f in "${archive_dir}/${prefix}-"*.jsonl; do
        [[ -f "$f" ]] || continue
        gzip -f "$f" 2>/dev/null && green "Compressed: $(basename "$f").gz"
      done
    fi
  else
    green "Log size does not exceed the threshold, no need to archive"
  fi

  # Clean up expired archives for this log target.
  if [[ -d "$archive_dir" ]]; then
    CUTOFF=$(date -v-${RETAIN_MONTHS}m +%Y-%m 2>/dev/null || date -d "${RETAIN_MONTHS} months ago" +%Y-%m 2>/dev/null || echo "")
    if [[ -n "$CUTOFF" ]]; then
      for f in "${archive_dir}/${prefix}-"*.jsonl.gz; do
        [[ -f "$f" ]] || continue
        MONTH=$(basename "$f" | sed "s/^${prefix}-\(.*\)\.jsonl\.gz$/\1/")
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
}

cleanup_stale_markers() {
  # Per-session learn-metrics warning dedup flags; useless once the session
  # is gone, and they otherwise accumulate forever (thousands of empty files).
  local stale_count
  stale_count=$(find "$LOG_DIR" -maxdepth 1 -name '.learn_metrics_truncated_*' -mtime +1 2>/dev/null | wc -l | tr -d ' ')
  [[ "$stale_count" -gt 0 ]] || return 0
  if [[ "$DRY_RUN" == "true" ]]; then
    yellow " [DRY-RUN] Delete ${stale_count} stale learn-metrics markers"
  else
    find "$LOG_DIR" -maxdepth 1 -name '.learn_metrics_truncated_*' -mtime +1 -delete 2>/dev/null || true
    green "Removed ${stale_count} stale learn-metrics markers"
  fi
}

processed=0
if [[ -f "$LOG_FILE" ]]; then
  gc_one_log_file "$LOG_FILE" "$ARCHIVE_DIR" "global log"
  processed=$((processed + 1))
fi

if [[ -f "$WRAPPER_LOG_FILE" ]]; then
  gc_one_log_file "$WRAPPER_LOG_FILE" "$ARCHIVE_DIR" "codex wrapper log" "codex-wrapper"
  processed=$((processed + 1))
fi

for project_log in "${LOG_DIR}"/projects/*/events.jsonl; do
  [[ -f "$project_log" ]] || continue
  gc_one_log_file "$project_log" "$(dirname "$project_log")/archive" "project log"
  processed=$((processed + 1))
done

cleanup_stale_markers

if [[ "$processed" -eq 0 ]]; then
  yellow "No log files found under: ${LOG_DIR}"
  exit 0
fi

green "Log GC completed"
