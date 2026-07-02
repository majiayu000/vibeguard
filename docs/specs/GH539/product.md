# Product Spec

## Linked Issue

GH-539

## User Problem

Under Claude Code, when the VibeGuard runtime is missing/unsupported (`policy_error`) or `~/.vibeguard/config.json` is malformed (`config_parse_error`), the Claude hook wrapper `hooks/run-hook.sh:71-75` prints a reason to stderr and `exit 1` — it emits no `{"decision":"block"}` and no `exit 2`. Per the Claude Code hook contract, that is a non-blocking error, so the guarded tool call proceeds. Every other guard path fails closed. The Codex wrapper fails closed for the same condition. This means a whole class of failures silently disables all Claude-side guards, and an agent can trigger it deliberately by writing a malformed config file (which no guard blocks).

## Goals

- Make Claude-side policy/runtime/config failures fail **closed** for enforcing PreToolUse/PermissionRequest events, matching the Codex wrapper.
- Keep the failure reason visible to the user (do not silently block with no explanation).
- Eliminate the silent divergence between the Claude and Codex wrappers for the same error classes.

## Non-Goals

- Changing PostToolUse/Stop hook behavior (those are advisory and must not block — see GH-related stop-hook work).
- Redesigning the policy/config parsing itself.
- Hardening the config file against agent writes (tracked separately; defense-in-depth, not this fix).

## Behavior Invariants

1. When `hooks/run-hook.sh` receives `policy_status` 20 (policy_error) or 30 (config_parse_error) for an enforcing PreToolUse/PermissionRequest event, the wrapper produces a blocking decision (`{"decision":"block"}` + `exit 0`, or `exit 2`) rather than `exit 1`.
2. The blocking decision carries a human-readable reason (the existing `VG_POLICY_REASON`) so the user can see why the tool call was denied.
3. The Claude and Codex wrappers produce semantically equivalent outcomes (block/deny) for the same `policy_status` error class.
4. Non-enforcing events (Stop, SessionStart, advisory PostToolUse) continue to exit 0 and never block, even on the same error class.
5. A malformed `~/.vibeguard/config.json` results in a visible block, not a silent allow, on the next enforcing Claude event.

## Acceptance Criteria

- [ ] `tests/hooks/test_runtime_policy.sh` asserts the Claude PreToolUse path emits a block decision (not a bare non-zero exit) on `policy_error` and `config_parse_error`.
- [ ] A test corrupts `~/.vibeguard/config.json` and verifies the next enforcing Claude event is blocked with a visible reason.
- [ ] Stop/SessionStart hooks still exit 0 under the same failure condition (no regression to the loop-safety invariant).
- [ ] Behavior documented so any intentional fail-open is explicit, not implicit.

## Edge Cases

- Runtime binary present but wrong version / unsupported subcommand → policy_error path.
- Config file empty vs partially written vs valid-JSON-but-wrong-schema.
- Warn-mode events (should remain non-blocking) vs block-mode events.
- Concurrent sessions all hitting the corrupted config simultaneously.

## Rollout Notes

This flips a currently-permissive failure mode to restrictive. After the change, a genuine config typo hard-blocks all enforcing tools until fixed — that is the intended fail-closed behavior, but the error message must be actionable (point the user at the offending file and how to reset it). Consider a one-line note in the changelog/README so users understand why a broken config now blocks.
