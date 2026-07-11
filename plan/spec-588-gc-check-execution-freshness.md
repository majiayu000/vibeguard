# SPEC: Scheduled GC execution-freshness check in setup --check (#588)

**Status**: Draft v1
**Closes**: #588 (P2, bug, dx)
**Depends on**: nothing (builds on the #499 registration/target-drift checks already in `scripts/setup/check.sh`)

---

## Problem

`setup.sh --check` validates scheduled-GC **registration** (`check_launchd_scheduled_gc()` at `scripts/setup/check.sh:159-205`: loaded label, plist presence, target-path drift) but never validates **execution**:

- `scripts/gc/gc-scheduled.sh:185-189` writes `~/.vibeguard/gc-last-attempt` and `~/.vibeguard/gc-last-success` after each run, and `scripts/gc/gc-scheduled.sh:26` defines `gc.catchup_interval_hours` (default 168). No consumer of these files exists outside gc-scheduled.sh itself (U-26 declared-but-unwired).
- When launchd fires but the job fails before producing output — observed failure mode: macOS TCC denies executing a script under `~/Desktop` and `gc-launchd.log` records `Operation not permitted` — GC stops silently for weeks with `--check` still reporting `[OK]` (U-29 silent degradation).

## Goals

1. `--check` warns when scheduled GC is registered but has not succeeded within the catchup interval.
2. `--check` surfaces the most recent scheduler-side failure evidence (`gc-launchd.log` / `gc-cron.log` error lines) with a remediation hint.
3. Same coverage on the systemd path as on launchd.

## Non-goals

- Not fixing the TCC failure itself (checkout location / Full Disk Access is an operator decision; `--check` only makes it visible).
- Not changing gc-scheduled.sh state-file semantics.
- Not making a missing scheduler an error — opt-in stays opt-in (`[INFO]` unchanged).

## Behavior invariants

| ID | Invariant |
|---|---|
| B-001 | Scheduler registered + `gc-last-success` fresher than `gc.catchup_interval_hours` → `[OK]` mentions last success age. |
| B-002 | Scheduler registered + `gc-last-success` missing or older than the interval → `[WARN] Scheduled GC registered but has not succeeded in ...` (yellow; `--strict` treats WARN per existing policy). |
| B-003 | `gc-last-attempt` newer than `gc-last-success` and a failure line exists in the scheduler log → the WARN includes the last error line (e.g. `Operation not permitted`) and a hint (`re-register via bash setup.sh --yes --with-scheduler; if EPERM under ~/Desktop, move the checkout or grant launchd disk access`). |
| B-004 | Scheduler not installed → existing `[INFO]` output unchanged (no freshness noise). |
| B-005 | Unreadable/garbled state files (non-numeric content) are treated as "no success recorded", never crash the check. |
| B-006 | systemd path (`vibeguard-gc.timer` active) applies B-001..B-005 with `gc-cron.log` as the log source. |

## Design

New helper in `scripts/setup/check.sh`, called from both the launchd and systemd branches after registration checks pass:

```
check_scheduled_gc_freshness <log_file>
  interval_h = vg_config_positive_int VIBEGUARD_GC_CATCHUP_INTERVAL_HOURS gc.catchup_interval_hours 168
  last_success = numeric contents of ~/.vibeguard/gc-last-success (else empty)
  last_attempt = numeric contents of ~/.vibeguard/gc-last-attempt (else empty)
  now - last_success <= interval_h*3600  -> green OK (age printed)
  else -> yellow WARN (age or "never"); if last_attempt > last_success,
          append last matching error line from <log_file> tail
```

- Config resolution reuses `scripts/lib/project_config.sh` (`vg_config_positive_int`), same as `scripts/gc/gc-scheduled.sh:22-26`.
- Log evidence: last line matching `Operation not permitted|\[ERROR\]` from the final 50 lines of the log file; absent log → generic WARN without evidence line.
- One caveat documented in the WARN text: `gc-last-attempt` is only written when gc-scheduled.sh itself runs; a TCC EPERM kills the job before any state write, so "attempt missing + log has EPERM" must also trigger B-003's evidence path (detect via log line newer than last_success mtime — fall back to plain B-002 WARN if timestamps are unparsable).

## Product-to-test mapping

| Behavior invariant | Implementation area | Verification |
|---|---|---|
| B-001, B-002 | `check_scheduled_gc_freshness` in `scripts/setup/check.sh` | new cases in `tests/test_setup.sh`: fake `gc-last-success` fresh → OK; stale/missing → WARN (assert exit + message) |
| B-003 | same helper, log-tail branch | fixture `gc-launchd.log` containing `Operation not permitted`; assert WARN embeds the line + hint |
| B-004 | call sites in launchd/systemd branches | existing not-installed test still passes unchanged |
| B-005 | numeric-parse guard | fixture state file with garbage bytes → WARN "never", exit 0 in non-strict |
| B-006 | systemd branch call site | Linux CI leg of `tests/test_setup.sh` with mocked `systemctl` |

## Verification plan

- `bash tests/test_setup.sh` (extended cases above) — must pass on macOS + ubuntu CI.
- Manual: on a machine with stale GC, `bash setup.sh --check` shows the WARN with age and log evidence.

## Rollback

Single additive helper + two call sites in `scripts/setup/check.sh` and test cases; revert the one commit to restore registration-only behavior. No state-file or scheduler changes to roll back.
