# Task Plan — GH659

## Linked Issue

GH-659

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP659-T1` Parameterize archive naming and select the Codex wrapper log. Covers: B-001, B-007. Owner: implementer. Dependencies: none. Writable files: `scripts/gc/gc-logs.sh`. Done when: all selected logs reuse one lock/atomic-replacement path and retain archives by prefix. Verify: focused GC rotation harness.
- [ ] `SP659-T2` Add byte-cap-aware selection, current-month overflow handling, and collision-proof archive allocation. Covers: B-002, B-003. Owner: implementer. Dependencies: SP659-T1. Writable files: `scripts/gc/gc-logs.sh`. Done when: 8–10 MiB inputs are processed, the newest complete line or explicit oversized-line exception stays live, and canonical plus colliding run-stamped gzip archives remain unchanged. Verify: focused GC rotation harness.
- [ ] `SP659-T3` Add stale learning-marker cleanup and make every dry-run action non-mutating and visible. Covers: B-004, B-006. Owner: implementer. Dependencies: SP659-T2. Writable files: `scripts/gc/gc-logs.sh`. Done when: stale, fresh, exact-boundary, and dry-run fixtures prove marker retention; dry-run does not create an archive directory and reports archive, compression, retention, and marker actions. Verify: focused GC rotation harness.
- [ ] `SP659-T4` Make the scheduled oversized-log scan total and successful for empty or below-threshold inputs. Covers: B-005. Owner: implementer. Dependencies: none. Writable files: `scripts/gc/gc-scheduled.sh`. Done when: the function scans wrapper/global/project logs and returns zero after a non-matching final candidate. Verify: `bash tests/test_gc_scheduled.sh`.
- [ ] `SP659-T5` Add the focused isolated regression harness and preserve all existing GC contract suites. Covers: B-001, B-002, B-003, B-004, B-005, B-006, B-007. Owner: implementer. Dependencies: SP659-T1, SP659-T2, SP659-T3, SP659-T4. Writable files: tests/test_gc_logs_rotation.sh (created by this task). Done when: the focused harness, GC config, scheduled GC, manifest contract, shell syntax, and diff checks pass. Verify: after creation, run bash tests/test_gc_logs_rotation.sh plus the commands in the tech spec test plan.

## Parallelization

SP659-T4 may run in parallel with the strictly sequential SP659-T1 → SP659-T2
→ SP659-T3 chain because its writable file is `scripts/gc/gc-scheduled.sh`
while that chain exclusively owns `scripts/gc/gc-logs.sh`. SP659-T5 owns only
the focused test harness and starts after all production tasks complete.

## Verification

- `bash -n scripts/gc/gc-logs.sh scripts/gc/gc-scheduled.sh`
- Focused GC rotation harness added by SP659-T5.
- `bash tests/test_gc_config.sh`
- `bash tests/test_gc_scheduled.sh`
- `bash tests/test_manifest_contract.sh`
- `git diff --check`

## Handoff Notes

The implementation must remain on the existing `fix/gh659-gc-log-rotation`
branch and must update its PR body to reference `docs/specs/GH659/`. After
merge, users must rerun `setup.sh` before installed GC scripts gain the fix.
