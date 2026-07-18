# Task Plan — GH661

## Linked Issue

GH-661

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP661-T1` Compose the generic nonzero exit reason and send the same evidence through diagnostic and visible-failure helpers without changing the dedicated exit-124 timeout branch. Covers: B-001, B-002, B-003. Owner: implementation agent. Dependencies: none. Writable files: `hooks/_lib/codex_runner.sh`. Done when: both surfaces contain the exit status, conventional signal decoding where applicable, preserved output, and the empty-output placeholder while timeout evidence is unchanged. Verify: `bash -n hooks/_lib/codex_runner.sh`.
- [ ] `SP661-T2` Add direct `codex_run_hook` cases to the existing protocol helper harness for exit 1 with empty streams, exit 143, stderr-only, stdout-only, and unchanged exit 124. Covers: B-001, B-002, B-003. Owner: verification agent. Dependencies: SP661-T1. Writable files: `tests/codex_runtime/protocol_helper_tests.sh`. Done when: assertions prove identical reason evidence on diagnostic and visible surfaces for all generic nonzero cases, preserve timeout behavior, and map every new executable line/conditional arm to a case (100% critical-path and at least 80% new-code line coverage under U-22). Verify: `bash tests/test_codex_runtime.sh`, which sources the focused fixture.

## Parallelization

T2 depends on the message contract implemented by T1. Keep both tasks in one
lane with ownership of `hooks/_lib/codex_runner.sh` and
`tests/codex_runtime/protocol_helper_tests.sh`.

## Verification

- `bash -n hooks/_lib/codex_runner.sh`
- `bash tests/test_codex_runtime.sh`
- `bash tests/test_hook_health.sh`
- `bash scripts/ci/validate-hooks.sh`
- `bash scripts/ci/validate-hooks-manifest.sh`

## Handoff Notes

The existing protocol helper test already has a direct runner harness adjacent
to the timeout case; no test-infrastructure postponement or U-22 waiver
remains. The implementation PR must include the explicit line/branch-to-case
coverage mapping before merge. Merge the corrected spec before updating
implementation PR #669.
