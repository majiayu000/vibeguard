# Tech Spec — Bound GC log and marker growth

## Linked Issue

GH-659

## Product Spec

`docs/specs/GH659/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Log archiver | `scripts/gc/gc-logs.sh:21-26`, `scripts/gc/gc-logs.sh:37-194` | Processes event logs with one hard-coded `events-` archive prefix and retains the entire newest month | Owns archive naming, locking, atomic replacement, compression, and retention |
| Log selection | `scripts/gc/gc-logs.sh:196-213` | Selects the global and project event logs only | Must add the Codex wrapper diagnostic log without duplicating the archiver |
| Scheduled scan | `scripts/gc/gc-scheduled.sh:45-57` | The final conditional can leave a nonzero function status when the last file is below threshold | A `set -e` caller can exit before later GC phases |
| Marker producer | `vibeguard-runtime/src/hook_orchestrator_learn.rs:94-125` | Creates one sanitized `.learn_metrics_truncated_*` marker per truncated session and does not remove it | GC must own bounded marker retention without changing the hook hot path |

## Proposed Design

1. Parameterize `gc_one_log_file` with an archive prefix and reuse it for the
   global event log, project event logs, and `codex-wrapper.jsonl`.
2. Pass the prefix into the embedded Python archiver and all compression and
   retention globs. Keep the existing lock and atomic-replacement sequence.
3. Keep the current-month cap as an internal 8192 KiB GC constant so this
   issue's explicit three-path scope does not create a new public configuration
   surface. Select a log when it reaches the existing archive threshold or its
   byte size exceeds this cap. Walk current-month lines newest-first by encoded
   byte length, always retain the newest complete line, and archive older
   overflow lines. A newest line larger than the cap is retained alone.
4. If the canonical compressed month archive exists, allocate a unique
   run-stamped basename with an exclusive-create loop that first confirms both
   its JSONL and gzip targets are absent. Compression must refuse overwrite;
   collision retries allocate another basename instead of replacing data.
5. Add a bounded top-level marker cleanup for
   `.learn_metrics_truncated_*`. Execution deletes markers older than one day;
   dry-run prints the same candidates without deleting them.
   Move archive-directory creation behind the execution branch and make
   dry-run report planned archive writes, compression, retention deletion, and
   marker deletion without mutating the filesystem.
6. End `find_oversized_logs` with an explicit successful return after scanning
   the wrapper, global event, and project event logs.
7. Add one focused GC rotation harness during the implementation; the spec PR
   describes that planned harness without treating its nonexistent path as a
   current documentation target.

<!-- specrail-planned-changes -->
```json
{
  "issue": 659,
  "complete": true,
  "paths": [
    "scripts/gc/gc-logs.sh",
    "scripts/gc/gc-scheduled.sh",
    "tests/test_gc_logs_rotation.sh"
  ],
  "spec_refs": [
    "docs/specs/GH659/product.md",
    "docs/specs/GH659/tech.md",
    "docs/specs/GH659/tasks.md"
  ]
}
```

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 | parameterized log archiver and wrapper-log selection | focused GC harness: wrapper archive prefix and valid live-file assertions |
| B-002 | byte-cap-aware selection and embedded Python current-month budget walk | focused GC harness: 8–10 MiB input, overflow archive, ordering, normal newest line, and oversized-newest-line exception |
| B-003 | exclusive unique archive-target allocation and non-clobbering compression | focused GC harness: canonical and colliding run-stamped archives remain byte-identical while a new unique archive is created |
| B-004 | top-level stale-marker cleanup | focused GC harness: stale/fresh/boundary marker fixtures |
| B-005 | explicit successful oversized-scan return | `bash tests/test_gc_scheduled.sh` plus a below-threshold final-file fixture |
| B-006 | non-mutating dry-run branches for directory creation and every action class | focused GC harness: absent archive directory, before/after filesystem snapshot, and archive/compression/retention/marker output assertions |
| B-007 | prefix-aware retention glob and month parsing | focused GC harness: expired and unexpired archives for both prefixes |

## Data Flow

Inputs are the configured log root, archive threshold, retention months, the
internal current-month byte cap, and optional dry-run flag. GC reads complete JSONL
lines while holding the existing per-log lock, writes unique archive JSONL
files, atomically replaces a processed live log, and compresses new archives.
It deletes only expired archives and stale learning markers selected under the
same configured root. There are no network calls or new credential surfaces.

## Alternatives Considered

- Add a second wrapper-specific archiver: rejected because it would duplicate
  locking, atomic replacement, compression, and retention semantics.
- Keep all current-month data live: rejected because a busy current month can
  remain permanently above the archive threshold.
- Clean `snapshot-drift/` and `circuit-breaker/` in the same PR: rejected as a
  separate retention-policy decision outside the issue's stated fix scope.

## Risks

- Security: all paths remain beneath the configured local log root; shell path
  values stay quoted and no command strings are evaluated.
- Compatibility: legacy `events-YYYY-MM.jsonl.gz` archives remain readable and
  subject to the same retention policy.
- Performance: processing remains threshold-or-cap-triggered and one pass per
  selected log; marker cleanup is bounded to the log root at depth one.
- Maintenance: archive-prefix and month parsing must share one implementation
  so wrapper and event retention cannot drift.

## Test Plan

- [ ] Focused tests: new isolated GC rotation harness for B-001 through B-007.
- [ ] Integration tests: `bash tests/test_gc_config.sh`,
      `bash tests/test_gc_scheduled.sh`, and
      `bash tests/test_manifest_contract.sh`.
- [ ] Static checks: `bash -n scripts/gc/gc-logs.sh scripts/gc/gc-scheduled.sh`
      and `git diff --check`.
- [ ] Manual verification: inspect dry-run output against an isolated fixture;
      never use the live user log root as automated test data.

## Rollback Plan

Revert the implementation commit and rerun `setup.sh` to restore installed
scripts. Archives already created remain ordinary gzip JSONL files and must not
be deleted during rollback.
