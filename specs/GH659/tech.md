# Tech Spec — GC log rotation covers wrapper log, marker files, and current-month growth

Linked Issue: #659
Product Spec: specs/GH659/product.md

## Codebase Context

- `scripts/gc/gc-logs.sh:23` — `LOG_FILE` points at `events.jsonl` only; the
  main loop archives `events.jsonl` and per-project logs, never
  `codex-wrapper.jsonl`.
- `scripts/gc/gc-logs.sh:42` (`gc_one_log_file`) — embedded Python archives
  non-current months to `events-<month>.jsonl` and keeps the whole current
  month in the main file, with no byte cap.
- `scripts/gc/gc-scheduled.sh:50-57` (`find_oversized_logs`) — ends with
  `[[ ... ]] && printf`, leaving a nonzero status when the last file is below
  threshold; kills `set -e` callers.
- `hooks/learn-evaluator.sh:52` — creates one `.learn_metrics_truncated_<id>`
  marker per session; no deleter exists anywhere on main (verified by grep).

## Design

1. Generalize `gc_one_log_file` with a fourth `prefix` argument (default
   `events`) used for archive names, compression glob, and retention glob.
2. Add `WRAPPER_LOG_FILE` and a second `gc_one_log_file` call with prefix
   `codex-wrapper`, reusing the same lock/atomic-replace machinery.
3. Cap current-month retention by `CURRENT_MONTH_MAX_KB`
   (`vg_config_positive_int VIBEGUARD_GC_CURRENT_MONTH_MAX_KB
   gc.current_month_max_kb 8192`): walk current-month lines newest-first,
   keep until the byte budget is spent, archive the overflow to a run-stamped
   file.
4. `archive_target(month)` returns a run-stamped path when
   `<prefix>-<month>.jsonl.gz` already exists, so `gzip -f` cannot clobber a
   prior month archive.
5. `cleanup_stale_markers`: `find "$LOG_DIR" -maxdepth 1 -name
   '.learn_metrics_truncated_*' -mtime +1 -delete`, honoring `--dry-run`.
6. `find_oversized_logs`: append explicit `return 0`.

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
  "spec_refs": ["specs/GH659/product.md", "specs/GH659/tech.md", "specs/GH659/tasks.md"]
}
```

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 wrapper log archived with codex-wrapper prefix | `gc-logs.sh` prefix arg + wrapper call | `tests/test_gc_logs_rotation.sh` "codex-wrapper.jsonl is covered by log GC" |
| B-002 current-month byte cap, newest kept | embedded Python budget walk | `tests/test_gc_logs_rotation.sh` "current-month byte cap archives overflow" |
| B-003 existing .gz not clobbered | `archive_target()` run-stamp branch | `tests/test_gc_logs_rotation.sh` "existing month .gz archive is not clobbered" |
| B-004 stale markers deleted, fresh kept | `cleanup_stale_markers` | `tests/test_gc_logs_rotation.sh` marker-cleanup checks |
| B-005 find_oversized_logs exits 0 | `gc-scheduled.sh` `return 0` | `bash -ec 'source ...; find_oversized_logs'` inside the test suite |
| B-006 dry-run mutates nothing | `_GC_DRY_RUN` branches + marker dry-run branch | dry-run checks in `tests/test_gc_logs_rotation.sh` |
| B-007 retention applies per prefix | retention glob `${prefix}-*.jsonl.gz` | retention check in `tests/test_gc_logs_rotation.sh` |

## Risks / Compatibility

- Existing `events-<month>.jsonl.gz` archives keep their name; retention sed
  is prefix-parameterized and still matches them.
- The byte cap defaults below the size threshold on purpose: a cap above the
  threshold would make the post-GC size re-check fail forever.
- Installed copies are stale until `setup.sh` reinstall (deployment note in
  product spec).

## Rollback

Revert the implementation commit; archives already written remain valid
(append-only gzip monthly files, format unchanged).
