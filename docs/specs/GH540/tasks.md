# Task Plan

## Linked Issue

GH-540

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP540-T1` Owner: agent — Add a triage projection at the guard-output path that appends a normalized row (rule ID, ts, context, decision) to `data/triage.jsonl`, reusing `hooks/_lib/log_write.sh` locking and `log_redact.sh` redaction. Done when: a guard warn/block appends one triage row. Verify: fire a guard in a test, assert a new row in `triage.jsonl`.
- [ ] `SP540-T2` Owner: agent — Add a classification entry point (extend a `/vibeguard:*` command or small script) that lists unclassified rows and records tp/fp. Done when: classifying updates the row and calls into scorecard update. Verify: run classify on a seeded row, assert row marked.
- [ ] `SP540-T3` Owner: agent — Wire classification into `scripts/precision-tracker.py` so tp/fp counters and precision update in the runtime scorecard generated from `data/rule-scorecard.seed.json`. Done when: a classified fp increments fp and recomputes precision. Verify: `python3 scripts/precision-tracker.py` shows non-null precision for the rule.
- [ ] `SP540-T4` Owner: agent — Add concurrent-append safety test and scorecard schema upgrade for legacy `samples:0` entries. Done when: parallel appends do not corrupt; old entries upgrade in place. Verify: run the concurrency test green.
- [ ] `SP540-T5` Owner: human — Confirm redaction covers triage context and that capture stays off the blocking latency path. Done when: reviewer approves. Verify: PR review approval recorded.

## Parallelization

T1 is the foundation; T2 and T3 depend on the row shape from T1. T4 can be written alongside once the shape is fixed. All touch `data/` + `scripts/precision-tracker.py` + hook libs — single owner to keep file ownership disjoint per W-14.

## Verification

- Run `python3 scripts/precision-tracker.py` and confirm a rule with recorded samples reports non-null precision.
- Manual: fire a known guard, classify the hit as fp, re-run tracker, confirm counters moved.

## Handoff Notes

Do not auto-label fp/tp — precision is only meaningful with human classification. Reuse the existing log locking/redaction rather than inventing a second write path. Lifecycle auto-transitions are intentionally out of scope until real data accumulates.
