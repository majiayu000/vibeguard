# Task Plan — GH659

Linked Issue: #659
Specs: specs/GH659/product.md, specs/GH659/tech.md

## Implementation Tasks

- SP659-T1 — Generalize `gc_one_log_file` with archive prefix and add the
  `codex-wrapper.jsonl` pass.
  Owner: agent. Depends: none.
  Done-when: wrapper log above threshold is archived to `codex-wrapper-*` gzip
  files and the main file keeps only current-month lines.
  Verify: `bash tests/test_gc_logs_rotation.sh`
  Covers: B-001, B-007

- SP659-T2 — Current-month byte cap with overflow archive and run-stamped
  no-clobber archive naming.
  Owner: agent. Depends: SP659-T1.
  Done-when: overflow lines land in a run-stamped archive, newest line stays
  in the main file, and a pre-existing `.gz` is never replaced.
  Verify: `bash tests/test_gc_logs_rotation.sh`
  Covers: B-002, B-003

- SP659-T3 — `cleanup_stale_markers` for `.learn_metrics_truncated_*`
  (>1 day), honoring dry-run.
  Owner: agent. Depends: none.
  Done-when: stale markers are deleted, fresh markers kept, dry-run only
  prints.
  Verify: `bash tests/test_gc_logs_rotation.sh`
  Covers: B-004, B-006

- SP659-T4 — `find_oversized_logs` returns 0 under `set -e`.
  Owner: agent. Depends: none.
  Done-when: sourcing the helper and running it on a below-threshold last file
  exits 0.
  Verify: `bash tests/test_gc_logs_rotation.sh`
  Covers: B-005

## Verification Tasks

- SP659-V1 — Full suite run: `bash tests/test_gc_logs_rotation.sh` (16
  checks) plus `bash tests/test_gc_config.sh` regression.
  Covers: B-001..B-007

## Handoff Notes

- Merge gate: human review + merge (maintainer).
- Post-merge: run `setup.sh` reinstall so `~/.vibeguard/installed/` picks up
  the fix; then one live `gc-logs.sh` run to drain the existing 17 MB
  wrapper log and 200+ stale markers.

## Coverage Check

Product IDs: B-001..B-007. Task coverage union: B-001..B-007. No mismatch.
