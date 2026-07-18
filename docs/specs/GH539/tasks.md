# Task Plan

## Linked Issue

GH-539

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP539-T1` Owner: agent — Extract a shared block-emit/reason helper in `hooks/_lib/policy.sh` used by both wrappers. Done when: a single function formats the policy block reason and both `run-hook.sh` and `run-hook-codex.sh` call it. Verify: `bash -n hooks/_lib/policy.sh` and existing policy tests still pass.
- [ ] `SP539-T2` Owner: agent — In `hooks/run-hook.sh`, replace the `exit 1` at :71-75 with an event-class branch: enforcing PreToolUse/PermissionRequest emits a block decision + exit 0; non-enforcing events keep exit 0 without blocking. Done when: policy_error/config_parse_error produce a block for enforcing events only. Verify: `tests/hooks/test_runtime_policy.sh` passes with updated assertions.
- [ ] `SP539-T3` Owner: agent — Update `tests/hooks/test_runtime_policy.sh` to assert Claude fail-closed (block decision, visible reason) and add a corrupt-config end-to-end case. Done when: tests assert block+reason, not bare non-zero. Verify: `bash tests/hooks/test_runtime_policy.sh`.
- [ ] `SP539-T4` Owner: agent — Add a Stop-hook regression asserting exit 0 under missing-runtime/broken-config. Done when: Stop path proven non-blocking under the failure. Verify: run the Stop regression test green.
- [ ] `SP539-T5` Owner: human — Security review of the fail-closed change (SEC-11 guard-enforcement path) and confirm the error message is actionable. Done when: reviewer approves. Verify: PR review approval recorded.

## Parallelization

T1 must land before T2 (T2 consumes the helper). T3 and T4 (tests) can be written in parallel with T2 but share `tests/hooks/` — single owner to avoid write conflicts. T5 gates merge.

## Verification

- Run `bash tests/hooks/test_runtime_policy.sh`; green with fail-closed assertions.
- Manual: corrupt config, then an enforcing Edit is blocked visibly; Stop still exits 0.

## Handoff Notes

The core insight: `exit 1` is non-blocking under Claude's PreToolUse contract, so it must become a decision-JSON block. Do not apply the block to Stop/SessionStart — that reintroduces the infinite-loop hazard `stop-guard.sh` documents (issues #3573/#10205). Mirror the Codex path exactly; the shared helper is what prevents future drift.
