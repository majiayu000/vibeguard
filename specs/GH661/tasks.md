# Task Plan — GH661

Linked Issue: #661
Specs: specs/GH661/product.md, specs/GH661/tech.md

- SP661-T1 — Build `nonzero_reason` (exit code, signal decode, `<no output>`
  placeholder) and thread it through `codex_diag` +
  `codex_visible_failure_raw` in the nonzero branch of `codex_run_hook`.
  Owner: agent. Depends: none.
  Done-when: both messages carry `exit=<code>` and never an empty reason.
  Verify: `bash -n hooks/_lib/codex_runner.sh` + `bash tests/codex_runtime/protocol_helper_tests.sh` + `bash tests/test_hook_health.sh`
  Covers: B-001, B-002, B-003

- SP661-T2 (DEFER) — Stub harness for `codex_run_hook` helpers enabling a
  dedicated test of the nonzero-without-output branch.
  Owner: maintainer decision. Depends: SP661-T1.
  Covers: none — test-infrastructure follow-up, recorded per U-22.

Coverage: B-001..B-003 mapped to SP661-T1. Merge gate: human review + merge.
