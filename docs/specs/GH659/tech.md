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
| Config schema | `schemas/vibeguard-project.schema.json:149-166`, `tests/test_gc_config.sh:57-165` | Declares and tests existing positive-integer GC settings | The new byte cap must not become an undeclared configuration field |

## Proposed Design

1. Parameterize `gc_one_log_file` with an archive prefix and reuse it for the
   global event log, project event logs, and `codex-wrapper.jsonl`.
2. Pass the prefix into the embedded Python archiver and all compression and
   retention globs. Keep the existing lock and atomic-replacement sequence.
3. Read `VIBEGUARD_GC_CURRENT_MONTH_MAX_KB` /
   `gc.current_month_max_kb` through `vg_config_positive_int`, defaulting to
   8192. Walk current-month lines newest-first by encoded byte length, always
   retain the newest complete line, and archive older overflow lines.
4. If the canonical compressed month archive exists, write new data to a
   unique run-stamped JSONL path before compression. Never invoke a clobbering
   compression operation on an existing archive.
5. Add a bounded top-level marker cleanup for
   `.learn_metrics_truncated_*`. Execution deletes markers older than one day;
   dry-run prints the same candidates without deleting them.
6. End `find_oversized_logs` with an explicit successful return after scanning
   the wrapper, global event, and project event logs.
7. Declare the new configuration property in the project schema and extend the
   existing GC config suite. Add one focused GC rotation harness during the
   implementation; the spec PR describes that planned harness without making
   its nonexistent path a live documentation reference.

<!-- specrail-planned-changes -->
```json
{
  "issue": 659,
  "complete": true,
  "paths": [
    "scripts/gc/gc-logs.sh",
    "scripts/gc/gc-scheduled.sh",
    "schemas/vibeguard-project.schema.json",
    "tests/test_gc_config.sh",
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
| B-002 | embedded Python current-month budget walk | focused GC harness: overflow archive, byte cap, ordering, and newest-line assertions |
| B-003 | unique archive-target selection | focused GC harness: pre-existing compressed archive remains byte-identical |
| B-004 | top-level stale-marker cleanup | focused GC harness: stale/fresh/boundary marker fixtures |
| B-005 | explicit successful oversized-scan return | `bash tests/test_gc_scheduled.sh` plus a below-threshold final-file fixture |
| B-006 | dry-run branches for every action class | focused GC harness: before/after filesystem snapshot and output assertions |
| B-007 | prefix-aware retention glob and month parsing | focused GC harness: expired and unexpired archives for both prefixes |
| B-008 | project schema and existing config helper | `bash tests/test_gc_config.sh` and `bash tests/test_manifest_contract.sh` |

## Data Flow

Inputs are the configured log root, archive threshold, retention months,
current-month byte cap, and optional dry-run flag. GC reads complete JSONL
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
- Performance: processing remains threshold-triggered and one pass per selected
  log; marker cleanup is bounded to the log root at depth one.
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
