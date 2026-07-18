# Task Plan — GH661

## Linked Issue

GH-661

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP661-T1` Compose the nonzero exit reason and send the same evidence through diagnostic and visible-failure helpers. Covers: B-001, B-002, B-003. Owner: implementation agent. Done when: both surfaces contain the exit status, conventional signal decoding where applicable, preserved output, and the empty-output placeholder. Verify: `bash -n hooks/_lib/codex_runner.sh`.
- [ ] `SP661-T2` Add direct `codex_run_hook` cases to the existing protocol helper harness for exit 1 with empty streams, exit 143, and nonempty stderr/stdout. Covers: B-001, B-002, B-003. Owner: implementation agent. Done when: assertions prove identical reason evidence on diagnostic and visible surfaces for all required cases. Verify: `bash tests/codex_runtime/protocol_helper_tests.sh`.

## Parallelization

T2 depends on the message contract implemented by T1. Keep both tasks in one
lane with ownership of `hooks/_lib/codex_runner.sh` and
`tests/codex_runtime/protocol_helper_tests.sh`.

## Verification

- `bash -n hooks/_lib/codex_runner.sh`
- `bash tests/codex_runtime/protocol_helper_tests.sh`
- `bash tests/test_hook_health.sh`
- `bash scripts/ci/validate-hooks.sh`
- `bash scripts/ci/validate-hooks-manifest.sh`

## Handoff Notes

The existing protocol helper test already has a direct runner harness adjacent
to the timeout case; no test-infrastructure postponement remains. Merge the
corrected spec before updating implementation PR #669.
