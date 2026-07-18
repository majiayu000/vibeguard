# Tech Spec — record exit code/signal when a wrapped hook dies

## Linked Issue

GH-661

## Product Spec

`docs/specs/GH661/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Wrapped-hook nonzero branch | `hooks/_lib/codex_runner.sh:142` | Logs captured output without the exit status and emits a generic visible failure | This is the information-losing branch |
| Existing direct runner harness | `tests/codex_runtime/protocol_helper_tests.sh:283` | Stubs runner helpers and asserts the adjacent timeout branch | It can cover the nonzero branch without new infrastructure |

## Proposed Design

In the generic nonzero branch, build `nonzero_reason="exit=${hook_exit}"`.
For statuses above 128, append the conventional signal decoding
` (signal $((hook_exit - 128)))`. Compose the reason with stderr when present,
otherwise stdout, otherwise `<no output>`. Send that same composed evidence to
both `codex_diag` and `codex_visible_failure_raw`.

Keep the exit-124 timeout branch and all pass/fail decisions unchanged.

<!-- specrail-planned-changes -->
```json
{
  "issue": 661,
  "complete": true,
  "paths": [
    "hooks/_lib/codex_runner.sh",
    "tests/codex_runtime/protocol_helper_tests.sh"
  ],
  "spec_refs": [
    "docs/specs/GH661/product.md",
    "docs/specs/GH661/tech.md",
    "docs/specs/GH661/tasks.md"
  ]
}
```

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 exit code in diagnostic and visible evidence while exit 124 stays on its timeout branch | Generic nonzero branch in `codex_run_hook`; direct runner fixture | `bash tests/test_codex_runtime.sh` sources the fixture and covers exit 1, stderr-only, stdout-only, and unchanged exit 124 |
| B-002 conventional signal decoding | Same branch and fixture | Focused exit-143 assertion in `bash tests/test_codex_runtime.sh` |
| B-003 `<no output>` placeholder | Same branch and fixture | Focused empty-stream assertion in `bash tests/test_codex_runtime.sh` |

## Data Flow

The wrapped hook supplies stdout, stderr, and a shell exit status. The runner
captures them, composes one nonzero evidence string, then sends that string to
the diagnostic and visible-failure helpers. No persistence or external call is
added.

## Alternatives Considered

- Keep the generic visible message and enrich diagnostics only: rejected
  because it would continue silent evidence loss on the user-visible surface.
- Add a new test harness: rejected because the existing protocol helper test
  already stubs and invokes `codex_run_hook`.

## Risks

- Security: no new input execution or trust boundary.
- Compatibility: failure text becomes more specific; status above 128 uses
  shell convention and cannot prove whether the child explicitly returned the
  high status.
- Performance: constant-time string composition on an existing error path.
- Maintenance: focused assertions bind both evidence surfaces to the same
  reason contract.

## Test Plan

- [ ] Unit tests: add direct nonzero runner cases for exit 1, exit 143, empty
      streams, stderr-only, stdout-only, and unchanged exit 124 to
      `tests/codex_runtime/protocol_helper_tests.sh`.
- [ ] Coverage evidence: map every added executable line and conditional arm to
      those direct cases. The generic nonzero branch is critical, so every new
      arm must execute (100% critical-path coverage); the resulting mapping
      must also demonstrate at least 80% new-code line coverage under U-22.
- [ ] Integration tests: run `bash tests/test_hook_health.sh`.
- [ ] Manual verification: run `bash -n hooks/_lib/codex_runner.sh`.

## Rollback Plan

Revert the implementation and focused test changes; failure messages return
to the previous information-losing format.
