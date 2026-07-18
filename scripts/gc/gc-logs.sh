#!/usr/bin/env bash
# VibeGuard GC — Log Archiving
#
# events.jsonl / codex-wrapper.jsonl archive (gzip) monthly when threshold is
# exceeded, retaining the last 3 months. The current month is additionally
# capped by encoded bytes so heavy-usage months cannot grow unbounded.
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
# Internal contract: keep this below the default 10 MiB archive threshold.
CURRENT_MONTH_MAX_BYTES=$((8192 * 1024))

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
  local file_size_bytes

  file_size_mb=$(du -m "$log_file" | cut -f1)
  file_size_bytes=$(wc -c < "$log_file" | tr -d '[:space:]')
  echo "Processing ${label}: ${log_file}"
  echo "Current log size: ${file_size_mb}MB (Threshold: ${THRESHOLD_MB}MB)"

  # Archive when either the configured threshold or the internal live-byte cap
  # is exceeded. Dry-run deliberately avoids directories, locks, and temp files.
  if [[ "$file_size_mb" -ge "$THRESHOLD_MB" || "$file_size_bytes" -gt "$CURRENT_MONTH_MAX_BYTES" ]]; then
    _GC_LOG_FILE="$log_file" \
    _GC_ARCHIVE_DIR="$archive_dir" \
    _GC_ARCHIVE_PREFIX="$prefix" \
    _GC_CURRENT_MONTH_MAX_BYTES="$CURRENT_MONTH_MAX_BYTES" \
    _GC_DRY_RUN="$([[ "$DRY_RUN" == "true" ]] && echo 1 || echo 0)" \
    _GC_RUN_STAMP="${_GC_RUN_STAMP:-}" \
    python3 <<'PYEOF'
import fcntl
import gzip
import json
import os
import tempfile
import time
from collections import defaultdict

log_file = os.environ['_GC_LOG_FILE']
archive_dir = os.environ['_GC_ARCHIVE_DIR']
prefix = os.environ.get('_GC_ARCHIVE_PREFIX', 'events')
max_current_bytes = int(os.environ['_GC_CURRENT_MONTH_MAX_BYTES'])
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

run_stamp = os.environ.get('_GC_RUN_STAMP') or time.strftime('%Y%m%dT%H%M%S')
reserved_paths = set()

def targets_absent(gzip_path):
    jsonl_path = gzip_path[:-3]
    return (gzip_path not in reserved_paths
            and not os.path.exists(gzip_path)
            and not os.path.exists(jsonl_path))

def archive_target(month):
    canonical = os.path.join(archive_dir, f'{prefix}-{month}.jsonl.gz')
    if targets_absent(canonical):
        reserved_paths.add(canonical)
        return canonical

    counter = 0
    while True:
        suffix = run_stamp if counter == 0 else f'{run_stamp}-{counter}'
        candidate = os.path.join(
            archive_dir, f'{prefix}-{month}-{suffix}.jsonl.gz')
        if targets_absent(candidate):
            reserved_paths.add(candidate)
            return candidate
        counter += 1

def write_compressed_archive(month, lines, description):
    target = archive_target(month)
    if dry_run:
        print(f' [DRY-RUN] Archive {description} -> {target}')
        print(f' [DRY-RUN] Compress archive -> {target}')
        return

    os.makedirs(archive_dir, mode=0o700, exist_ok=True)
    # Exclusive creation is the final collision check. A collision between
    # candidate selection and creation retries with a fresh counter suffix.
    while True:
        try:
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            break
        except FileExistsError:
            reserved_paths.discard(target)
            target = archive_target(month)

    try:
        with os.fdopen(fd, 'wb') as raw:
            with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as zipped:
                zipped.write(('\n'.join(lines) + '\n').encode('utf-8'))
            raw.flush()
            os.fsync(raw.fileno())
        dir_fd = os.open(archive_dir, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except Exception:
        try:
            os.unlink(target)
        except FileNotFoundError:
            pass
        raise
    print(f'Archived {description} -> {target}')
    print(f'Compressed: {os.path.basename(target)}')

lock_fd = None if dry_run else acquire_lock()
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
    if current_lines:
        # The newest complete line is always live, even when that single line
        # is itself larger than the cap. Add older lines newest-first only
        # while they fit the remaining byte budget.
        keep_from = len(current_lines) - 1
        budget = max_current_bytes - len(current_lines[-1].encode('utf-8')) - 1
        for idx in range(len(current_lines) - 2, -1, -1):
            line_bytes = len(current_lines[idx].encode('utf-8')) + 1
            if line_bytes > budget:
                break
            budget -= line_bytes
            keep_from = idx
        overflow = current_lines[:keep_from]
        current_lines = current_lines[keep_from:]
    kept.extend(current_lines)

    archived = 0
    for month, lines in sorted(months.items()):
        write_compressed_archive(month, lines, f'{len(lines)} items')
        archived += len(lines)

    if overflow:
        write_compressed_archive(
            current_month, overflow,
            f'current-month overflow {len(overflow)} items')
        archived += len(overflow)

    if not dry_run and archived > 0:
        atomic_replace_log(kept)

    print(f'Total {total} items, archive {archived} items, retain {len(kept)} items')
finally:
    if lock_fd is not None:
        release_lock(lock_fd)
PYEOF
  else
    green "Log size does not exceed the threshold or current-month cap, no need to archive"
  fi

}

cleanup_expired_archives() {
  local archive_dir="$1"
  local prefix="$2"
  local cutoff file month
  [[ -d "$archive_dir" ]] || return 0

  cutoff=$(date -v-${RETAIN_MONTHS}m +%Y-%m 2>/dev/null \
    || date -d "${RETAIN_MONTHS} months ago" +%Y-%m 2>/dev/null \
    || echo "")
  [[ -n "$cutoff" ]] || return 0

  for file in "${archive_dir}/${prefix}-"*.jsonl.gz; do
    [[ -f "$file" ]] || continue
    month=$(basename "$file" | sed "s/^${prefix}-\(.*\)\.jsonl\.gz$/\1/")
    if [[ "$month" < "$cutoff" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        yellow " [DRY-RUN] Delete expired archives: $(basename "$file")"
      else
        rm "$file"
        yellow "Expired archive deleted: $(basename "$file")"
      fi
    fi
  done
}

cleanup_stale_markers() {
  # Per-session learn-metrics warning dedup flags; useless once the session
  # is gone, and they otherwise accumulate forever (thousands of empty files).
  _GC_LOG_DIR="$LOG_DIR" \
  _GC_DRY_RUN="$([[ "$DRY_RUN" == "true" ]] && echo 1 || echo 0)" \
  _GC_NOW_EPOCH="${_GC_NOW_EPOCH:-}" \
  python3 <<'PYEOF'
import os
import time

log_dir = os.environ['_GC_LOG_DIR']
dry_run = os.environ['_GC_DRY_RUN'] == '1'
now = float(os.environ.get('_GC_NOW_EPOCH') or time.time())
cutoff = now - 86400

if not os.path.isdir(log_dir):
    raise SystemExit(0)

stale = []
for entry in os.scandir(log_dir):
    if not entry.name.startswith('.learn_metrics_truncated_'):
        continue
    if entry.stat(follow_symlinks=False).st_mtime < cutoff:
        stale.append(entry)

for entry in sorted(stale, key=lambda item: item.name):
    if dry_run:
        print(f' [DRY-RUN] Delete stale learn-metrics marker: {entry.name}')
    else:
        os.unlink(entry.path)

if stale and not dry_run:
    print(f'Removed {len(stale)} stale learn-metrics markers')
PYEOF
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

cleanup_expired_archives "$ARCHIVE_DIR" "events"
cleanup_expired_archives "$ARCHIVE_DIR" "codex-wrapper"

for project_dir in "${LOG_DIR}"/projects/*; do
  [[ -d "$project_dir" ]] || continue
  project_log="${project_dir}/events.jsonl"
  if [[ -f "$project_log" ]]; then
    gc_one_log_file "$project_log" "${project_dir}/archive" "project log"
    processed=$((processed + 1))
  fi
  cleanup_expired_archives "${project_dir}/archive" "events"
done

cleanup_stale_markers

if [[ "$processed" -eq 0 ]]; then
  yellow "No log files found under: ${LOG_DIR}"
  exit 0
fi

green "Log GC completed"
