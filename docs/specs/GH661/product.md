# Product Spec — record exit code/signal when a wrapped hook dies

## Linked Issue

GH-661

complexity: trivial

## User Problem

When a wrapped Codex hook exits nonzero, the diagnostic log and user-visible
failure can omit the exit status and, when both output streams are empty, the
only available forensic evidence. Users cannot distinguish an ordinary
failure from a conventional signal-style exit.

## Goals

- Preserve the wrapped hook's nonzero exit status in both diagnostic and
  user-visible failure evidence.
- Preserve captured stderr/stdout and show an explicit placeholder when both
  streams are empty.

## Non-Goals

- No change to hook execution, timeout handling for exit 124, or the pass/fail
  decision.
- No claim that a status above 128 proves signal termination; the signal text
  is a conventional shell decoding of the status.

## Behavior Invariants

1. B-001: A wrapped-hook exit handled by the generic nonzero branch (all
   nonzero statuses except the dedicated timeout status 124) includes
   `exit=<code>` in both the diagnostic entry and user-visible failure,
   alongside captured stderr or stdout when present. Exit 124 keeps the
   existing timeout-specific evidence unchanged.
2. B-002: A status above 128 additionally includes the conventional
   `(signal N)` decoding where `N = code - 128`.
3. B-003: In that generic nonzero branch, when both output streams are empty,
   both evidence surfaces include `<no output>` instead of an empty reason.

## Acceptance Criteria

- [ ] Exit 1 with empty stdout/stderr produces `exit=1: <no output>` in both
      diagnostic and user-visible failure evidence.
- [ ] Exit 143 includes `exit=143 (signal 15)` in both evidence surfaces.
- [ ] A stderr-only failure preserves stderr alongside the exit reason, and a
      separate stdout-only failure preserves stdout alongside the exit reason.
- [ ] Exit 124 continues to use the existing timeout-specific evidence without
      the generic nonzero message contract.
- [ ] Direct cases exercise every new executable line and each critical branch
      (ordinary exit, signal-style exit, stderr-only, stdout-only, and empty
      output), providing 100% critical-path coverage and at least 80% line
      coverage for the new code as required by U-22.
- [ ] The focused runner tests and existing hook-health suite pass fresh.

## Boundary Checklist

| Category | Verdict (covered: B-xxx / N/A + reason) |
| --- | --- |
| Empty / missing input | covered: B-003 |
| Error / failure paths | covered: B-001, B-002, B-003 |
| Authorization / permission | N/A — reporting an already observed child status requires no new authority |
| Concurrency / race | N/A — no shared state or concurrent coordination changes |
| Retry / idempotency | N/A — the runner does not add or alter retries |
| Illegal state transitions | N/A — hook status decisions are unchanged |
| Compatibility / migration | covered: B-001, B-002 — evidence is additive; explicit high statuses remain indistinguishable from signal-style statuses |
| Degradation / fallback | covered: B-003 |
| Evidence / audit integrity | covered: B-001, B-002, B-003 |
| Cancellation / interruption | N/A — interruption behavior is unchanged; only its observed status is reported |

## Rollout Notes

No migration is required. The change is limited to additive failure evidence.
