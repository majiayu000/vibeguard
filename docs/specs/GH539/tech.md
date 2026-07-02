# Tech Spec

## Linked Issue

GH-539

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Claude wrapper | `hooks/run-hook.sh:71-75` | `policy_error`/`config_parse_error` → stderr + `exit 1` (non-blocking) | The defect site |
| Codex wrapper | `hooks/run-hook-codex.sh`, `hooks/_lib/policy.sh` (`vg_policy_codex_gate`, `vg_policy_codex_error_output`) | Same error class → `permissionDecision:deny` | The fail-closed reference to mirror |
| Enforcement contract | `docs/internal/benchmarks/benchmark-design.md:63,394` | "exit 2 = Block"; block guaranteed only via exit 2 / decision JSON | Defines what "blocking" means |
| Tests | `tests/hooks/test_runtime_policy.sh:307-334` | Asserts Claude "exits non-zero, no deny JSON"; Codex emits deny | Must be updated to assert fail-closed |
| Event classing | `hooks/run-hook.sh` (wrapper), `hooks/stop-guard.sh`, `hooks/log.sh` | Stop/SessionStart must never block | Must exclude non-enforcing events from the new block path |

## Proposed Design

In `hooks/run-hook.sh`, on `policy_status` 20/30, branch on event class:

- Enforcing PreToolUse / PermissionRequest → emit the same blocking output the guards use (`printf '{"decision":"block","reason":"..."}'` to stdout + `exit 0`, or `exit 2`), reusing `VG_POLICY_REASON`. Prefer reusing the existing helper that guards call so the JSON shape stays consistent.
- Non-enforcing events (Stop, SessionStart, advisory PostToolUse) → keep current visible-but-allow (`exit 0`), never block.

Factor the block-emit into a shared `_lib/policy.sh` helper if one does not already exist, so the Claude and Codex wrappers call the same reason-formatting logic and cannot drift again.

## Product-to-Test Mapping

| Product invariant | Implementation area | Verification |
| --- | --- | --- |
| P1 block on policy/config error | `run-hook.sh` policy branch | `test_runtime_policy.sh` asserts block decision, not bare exit 1 |
| P2 visible reason | reuse `VG_POLICY_REASON` | test asserts reason string present in output |
| P3 Claude/Codex parity | shared `_lib/policy.sh` helper | differential test comparing both wrappers on same input |
| P4 Stop never blocks | event-class guard in wrapper | test fires Stop with broken runtime, asserts exit 0 |
| P5 corrupt config blocks | end-to-end | test writes `{` to config, asserts next enforcing event blocked |

## Data Flow

stdin tool event → `run-hook.sh` resolves policy via runtime → `policy_status` → (new) event-class branch → block decision JSON on stdout / exit code. Reads `~/.vibeguard/config.json` (via runtime). No new persistence.

## Alternatives Considered

- Keep fail-open on Claude and document it: rejected — contradicts the product's core promise and the Codex path.
- `exit 2` instead of decision JSON: acceptable, but decision JSON carries a user-visible reason and matches how every other guard blocks; prefer decision JSON for PreToolUse.

## Risks

- Security: positive — closes a global bypass.
- Compatibility: a broken config now blocks all enforcing tools until fixed; mitigate with an actionable error message.
- Performance: negligible (same code path, different terminal output).
- Maintenance: reduces drift by sharing the reason-formatting helper across wrappers.

## Test Plan

- [ ] Unit tests: `test_runtime_policy.sh` updated for Claude fail-closed on policy_error + config_parse_error.
- [ ] Integration tests: corrupt-config end-to-end block; Stop-hook exit-0-under-failure regression.
- [ ] Manual verification: `echo '{' > ~/.vibeguard/config.json`, run an Edit, confirm visible block; restore config, confirm normal operation.

## Rollback Plan

Revert the `run-hook.sh` policy branch to the prior `exit 1`. Change is confined to the wrapper plus test assertions; no data migration.
