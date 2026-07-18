# Product Spec — GC log rotation covers wrapper log, marker files, and current-month growth

Linked Issue: #659
complexity: small

## Goals

Stop the three verified unbounded-growth paths under `~/.vibeguard/`:
codex-wrapper.jsonl is never archived, per-session learn-metrics marker files
are never deleted, and a heavy month can keep events.jsonl above the GC size
threshold until month rollover. Also fix the `gc-scheduled.sh` helper whose
trailing status kills `set -e` callers.

## Non-Goals

- Cleanup of `snapshot-drift/` (590 entries) and `circuit-breaker/` (102
  entries) directories. Tracked as follow-up; not in this change.
- Any change to event log write paths or hook hot paths.
- Changing default thresholds (10 MB log threshold, 3-month retention).

## Behavior Invariants

- B-001: When `codex-wrapper.jsonl` is at or above the GC size threshold,
  running `gc-logs.sh` archives its non-current-month lines to gzip monthly
  archives with the `codex-wrapper-` prefix, and the main file retains only
  current-month lines.
- B-002: Current-month lines in an archived log are capped by a configurable
  byte budget (`gc.current_month_max_kb`, default 8192 KB, below the 10 MB
  threshold). Overflow is archived, newest lines are kept in the main file,
  and the newest line always stays in the main file.
- B-003: When a compressed monthly archive (`<prefix>-<month>.jsonl.gz`)
  already exists, a new run writes to a run-stamped archive name instead of
  silently replacing the existing `.gz`.
- B-004: `.learn_metrics_truncated_*` marker files older than 1 day are
  deleted by `gc-logs.sh`; markers touched within the last day are kept so
  same-session warning dedup still works.
- B-005: `gc-scheduled.sh::find_oversized_logs` exits with status 0 when the
  last scanned file is below threshold, so `set -e` callers are not killed.
- B-006: `--dry-run` prints every planned archive/delete action and modifies
  no file.
- B-007: Monthly archives older than the retention window are deleted for
  every archive prefix, not only `events-`.

## Boundary Checklist

| Category | Verdict |
| --- | --- |
| Empty / missing input | covered: B-005 (empty candidate set), plus existing "No log files found" path unchanged |
| Error and failure paths | covered: B-003 (pre-existing .gz), B-005 (nonzero trailing status) |
| Authorization / permission | N/A — local files under the user's own `~/.vibeguard` |
| Concurrency / race / ordering | covered: existing flock-based lock in `gc_one_log_file` is reused for the wrapper log (B-001) |
| Retry / repetition / idempotency | covered: B-003 (re-run does not clobber), B-004 (delete is idempotent) |
| Illegal state transitions | N/A — no state machine |
| Compatibility / migration | covered: B-007 (old `events-` archives keep working); no format change to live logs |
| Degradation / fallback | covered: B-006 (dry-run is explicit, not silent) |

## Acceptance

`bash tests/test_gc_logs_rotation.sh` passes (16 checks), and a live run on a
machine with an oversized `codex-wrapper.jsonl` shrinks the main file while
producing gzip archives.

## Open Questions

- Deployment: installed copies under `~/.vibeguard/installed/` only pick up
  the fix after `setup.sh` reinstall; the release note must say so.
