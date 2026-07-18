# Product Spec — record exit code/signal when a wrapped hook dies without output

Linked Issue: #661
complexity: trivial

## Goals

When a wrapped Codex hook exits nonzero without producing stdout/stderr
(e.g. EMFILE, OOM-kill, signal), the diag log and the user-visible failure
message currently carry an empty reason — the exit code, the only forensic
signal, is lost. Surface it.

## Non-Goals

No change to hook execution, timeout handling (exit 124 path), or the
pass/fail decision; message content only.

## Behavior Invariants

- B-001: A nonzero wrapped-hook exit logs `exit=<code>` in both the
  `codex_diag` entry and the user-visible failure message, alongside any
  captured stderr/stdout.
- B-002: Exit codes above 128 additionally decode the terminating signal as
  `(signal N)`.
- B-003: When both output streams are empty, the reason shows `<no output>`
  instead of an empty string.

## Boundary Checklist

Empty/missing input: covered B-003. Error paths: covered B-001/B-002 (this
whole change is the error path). Other categories N/A — log formatting only.

## Acceptance

Existing suites covering the runner pass fresh
(`tests/codex_runtime/protocol_helper_tests.sh`, `tests/test_hook_health.sh`).

## Open Questions

- DEFER (U-22): no dedicated unit test exercises the nonzero-without-output
  branch; `codex_run_hook` needs a stub harness for its helpers first.
  Tracked as review focus in the implementation PR, not silently skipped.
