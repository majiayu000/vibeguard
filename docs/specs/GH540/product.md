# Product Spec

## Linked Issue

GH-540

## User Problem

VibeGuard ships a full guard-precision pipeline — `scripts/precision-tracker.py`, `data/rule-scorecard.json`, `data/triage.jsonl`, and the `guard-precision-tracker` skill — but it has never received data. `triage.jsonl` has zero data rows; every scorecard entry is `samples: 0, precision: null`, last updated 2026-03-24. The rule lifecycle (experimental → warn → error → demoted → disabled) cannot run, so no rule has ever been promoted or demoted on evidence. The product claims to track false positives, but operates blind.

## Goals

- Make guard warn/block decisions produce triage records that flow into `data/triage.jsonl`.
- Have `rule-scorecard.json` accumulate real TP/FP counts so the lifecycle state machine can run.
- Give the user a low-friction way to mark a guard hit as false positive vs true positive.

## Non-Goals

- Auto-tuning or auto-disabling rules in this change (lifecycle transitions can remain a follow-up once data exists).
- Changing guard detection logic itself.
- Building a UI beyond the existing skill/command surface.

## Behavior Invariants

1. When an enforcing or warn guard fires, a triage-eligible record can be appended to `data/triage.jsonl` with rule ID, timestamp, file/context, and decision.
2. A user (or `/vibeguard:*` command) can classify a recorded hit as `tp` or `fp`, updating the corresponding `rule-scorecard.json` counters.
3. `precision-tracker.py` computes precision from accumulated counters and reflects it in the scorecard.
4. Records are append-only; concurrent sessions do not corrupt `triage.jsonl`.
5. Capture is off the blocking critical path or asynchronous, so it does not add user-visible latency to the guard decision.

## Acceptance Criteria

- [ ] A guard hit produces a triage record (verified by a test that fires a guard and inspects `triage.jsonl`).
- [ ] Classifying a record as fp/tp updates `rule-scorecard.json` counters and recomputes precision.
- [ ] `precision-tracker.py` reports non-null precision for a rule with recorded samples.
- [ ] Concurrent appends do not interleave/corrupt lines.

## Edge Cases

- Guard fires but the session ends before classification (record stays unclassified — must not count as tp or fp).
- Same rule fires many times in one session (dedup vs count policy documented).
- Scorecard schema evolution (old entries with `samples:0` must upgrade cleanly).

## Rollout Notes

Backfill is not required; the scorecard simply starts accumulating from adoption. Document that pre-adoption precision is unmeasured. Once data flows for a few weeks, a follow-up can enable evidence-based lifecycle transitions.
