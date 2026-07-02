# Tech Spec

## Linked Issue

GH-540

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Precision tracker | `scripts/precision-tracker.py` (613 lines) | Computes precision from scorecard; never fed | Consumer of the data we must produce |
| Scorecard | `data/rule-scorecard.json` | All entries `samples:0, precision:null`, stale 2026-03-24 | The store to populate |
| Triage log | `data/triage.jsonl` | Header/comments only, no rows | The capture sink |
| Skill | `guard-precision-tracker` skill | Documents the workflow, no live wiring | Entry point to align |
| Guard output | `hooks/*guard*.sh`, `hooks/_lib/log_write.sh` | Emits warn/block + logs events to `events.jsonl` | Natural hook to also emit triage records |

## Proposed Design

Reuse the existing event-log path. Guard hits already write to `events.jsonl` via `vg_log`; add a triage projection: when a guard emits a warn/block with a rule ID, append a normalized triage-candidate line to `data/triage.jsonl` (append-only, same locking discipline as `log_write.sh`). Provide a classification entry point (extend an existing `/vibeguard:*` command or add a small script) that reads unclassified triage rows and lets the user mark tp/fp, updating `rule-scorecard.json` via `precision-tracker.py`. Keep capture asynchronous/append-only so the guard decision latency is unchanged.

## Product-to-Test Mapping

| Product invariant | Implementation area | Verification |
| --- | --- | --- |
| P1 triage record on hit | guard → triage projection | test fires guard, asserts row in triage.jsonl |
| P2 tp/fp classification | classification command + precision-tracker | test classifies, asserts scorecard counters change |
| P3 precision computed | `precision-tracker.py` | test asserts non-null precision after samples |
| P4 append-only safety | reuse `log_write.sh` lock | concurrent-append test, no corruption |
| P5 no added latency | capture off critical path | timing assertion or code review |

## Data Flow

Guard decision → (new) triage projection appends JSONL row → user/command classifies → `precision-tracker.py` updates `rule-scorecard.json`. Persistence: `data/triage.jsonl` (append-only), `data/rule-scorecard.json` (rewrite). No external calls.

## Alternatives Considered

- Fully automatic fp inference: rejected — fp/tp is a human judgment; auto-labeling would poison precision.
- Separate new log file instead of reusing `log_write.sh` discipline: rejected — duplicates locking/redaction logic.

## Risks

- Security: triage rows may contain file paths/snippets — reuse `log_redact.sh` redaction.
- Compatibility: scorecard schema must upgrade `samples:0` entries in place.
- Performance: capture must stay append-only/async to avoid hot-path cost.
- Maintenance: keep a single projection point so guards do not each reimplement triage emission.

## Test Plan

- [ ] Unit tests: triage projection emits a well-formed row; classification updates counters.
- [ ] Integration tests: end-to-end guard-hit → classify → precision recomputed.
- [ ] Manual verification: fire a known guard, run the classify command, inspect scorecard.

## Rollback Plan

Disable the triage projection (feature flag or revert the guard hook addition); `triage.jsonl`/scorecard remain readable. No migration to undo.
