# Product Spec — Bound GC log and marker growth

## Linked Issue

GH-659

complexity: medium

## User Problem

VibeGuard's scheduled garbage collection does not currently include the Codex
wrapper diagnostic log or old per-session learning truncation markers. The
wrapper log and marker count can therefore grow without a bound, while a
trailing nonzero shell status can also stop scheduled GC before later cleanup
steps run.

## Goals

- Archive oversized `codex-wrapper.jsonl` data with the same durability and
  retention guarantees as event logs.
- Bound the live current-month portion of each archived log while preserving
  the newest complete line.
- Remove stale `.learn_metrics_truncated_*` markers without removing markers
  still needed for same-session warning deduplication.
- Make the oversized-log scan safe for `set -e` callers.
- Keep dry-run output complete and non-mutating.

## Non-Goals

- Cleanup policy for `snapshot-drift/` or `circuit-breaker/`; the issue's
  implementation scope explicitly limits this change to logs, learning
  markers, and the scheduled scan status.
- Changes to event-log or hook hot-path writers.
- Changes to the existing 10 MB archive threshold or three-month retention
  defaults.

## Behavior Invariants

1. B-001: When `codex-wrapper.jsonl` reaches the configured archive threshold,
   GC archives older data under a distinct `codex-wrapper-` prefix and keeps a
   valid live file.
2. B-002: A selected log is processed when it reaches the existing archive
   threshold or when its live bytes exceed the internal 8192 KiB current-month
   cap. Overflow is archived and the newest complete line always remains live.
   If that single newest line exceeds the cap, it is the only live line and is
   the explicit bounded-record exception.
3. B-003: A GC run never overwrites an existing compressed monthly archive;
   additional data uses a unique run-stamped archive name.
4. B-004: Learning truncation markers older than one day are removed, while
   markers no older than one day are preserved.
5. B-005: The oversized-log scan returns success when no candidate is
   oversized, including when the final scanned file is below threshold.
6. B-006: Dry-run reports every archive, compression, retention, and marker
   deletion it would perform and makes no filesystem changes.
7. B-007: Retention deletes expired compressed archives for every supported
   prefix without changing live logs or unexpired archives.

## Acceptance Criteria

- [ ] A focused deterministic GC regression harness covers B-001 through
      B-007 on isolated temporary log roots.
- [ ] Existing GC configuration and scheduled-GC suites remain green.
- [ ] The implementation PR documents that installed copies require a
      `setup.sh` reinstall before the change takes effect.

## Boundary Checklist

| Category | Verdict (covered: B-xxx / N/A + reason) |
| --- | --- |
| Empty / missing input | covered: B-005; an empty candidate set succeeds |
| Error / failure paths | covered: B-003; canonical and unique archive paths are never clobbered |
| Authorization / permission | N/A — GC only operates on the user's configured local VibeGuard log root |
| Concurrency / race | covered: B-001, B-003; the existing per-log lock is preserved and archive names do not collide |
| Retry / idempotency | covered: B-003, B-004, B-007 |
| Illegal state transitions | N/A — no persistent workflow state machine changes |
| Compatibility / migration | covered: B-001, B-007; existing event archive names remain supported |
| Degradation / fallback | covered: B-006; no silent fallback is introduced |
| Evidence / audit integrity | covered: B-006; dry-run enumerates the same action classes as execution |
| Cancellation / interruption | covered: B-001, B-003; live-log replacement remains atomic and existing archives are preserved |

## Rollout Notes

Installed copies under `~/.vibeguard/installed/` remain unchanged until the
user reruns `setup.sh`. After reinstall, one GC run can drain pre-existing
oversized wrapper logs and stale markers.
