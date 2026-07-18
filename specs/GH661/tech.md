# Tech Spec — record exit code/signal when a wrapped hook dies without output

Linked Issue: #661
Product Spec: specs/GH661/product.md
complexity: trivial

## Codebase Context

- `hooks/_lib/codex_runner.sh:131` — the `hook_exit -ne 0` branch logs only
  `${hook_err:-${hook_output}}`; when both are empty the diag reason and the
  visible failure text are empty.
- The timeout branch just above (exit 124) already carries an explicit
  reason; this change mirrors that shape for the generic nonzero branch.

## Design

Build `nonzero_reason="exit=${hook_exit}"`, append ` (signal N)` when
`hook_exit > 128`, and emit
`"${nonzero_reason}: ${hook_err:-${hook_output:-<no output>}}"` through both
`codex_diag` and `codex_visible_failure_raw`.

<!-- specrail-planned-changes -->
```json
{
  "issue": 661,
  "complete": true,
  "paths": [
    "hooks/_lib/codex_runner.sh"
  ],
  "spec_refs": ["specs/GH661/product.md", "specs/GH661/tech.md", "specs/GH661/tasks.md"]
}
```

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 exit code in diag + visible message | nonzero branch in `codex_run_hook` | `bash -n hooks/_lib/codex_runner.sh` + fresh run of `tests/codex_runtime/protocol_helper_tests.sh` and `tests/test_hook_health.sh`; dedicated branch test DEFERred (product spec open question) |
| B-002 signal decode >128 | same branch | same as B-001 |
| B-003 `<no output>` placeholder | same branch | same as B-001 |

## Rollback

Revert the commit; messages return to the prior (information-losing) form.
