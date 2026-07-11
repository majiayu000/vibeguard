# SPEC: W-14 overlap warning per-pair cooldown (#590)

**Status**: Draft v1
**Closes**: #590 (P2, guard, false positive)
**Depends on**: nothing

---

## Problem

The W-14 cross-session overlap detector warns on **every** edit that overlaps a recent peer edit, with no repeat suppression:

- Rust production path: `vibeguard-runtime/src/hook_orchestrator_post_edit_history.rs:101-118` (`detect_w14`) — fires whenever `recent_overlap` matches; no state consulted.
- Shell fallback path: `hooks/_lib/post_edit_history.sh:139-155` (`vg_post_edit_detect_w14_overlap`) — same behavior.

Observed in this repo's event log (2026-06-01→07-11, 9088 events): W-14 variants are 4 of the top 12 warn reasons, with 17 generic hits and 8/4/3 repeats against the *same* peer session. After the first warning the repeats carry no new information — deliberate claude+codex parallel work on hot files becomes a noise stream that trains users to ignore W-14 (precedent: #255/#253, fixed for other guards; existing watermark pattern: `hooks/skills-loader.sh:126-210`).

The generic circuit breaker (`vibeguard-runtime/src/circuit_breaker.rs`) is a different mechanism (block-rate based, per hook) and does not address per-finding repeat noise.

## Goals

1. First W-14 hit per (file, peer session) stays a full actionable warning (worktree FIX block unchanged).
2. Repeats within a cooldown window are suppressed from agent-visible output but still logged for observability.
3. Same semantics in the Rust path and the shell fallback path (contract parity, cf. closed #430 drift lesson).

## Non-goals

- No change to overlap *detection* (window, session/agent matching in `recent_overlap`).
- No suppression across different files or different peer sessions.
- Not touching W-15/CHURN detectors (separate signals, separate tuning).

## Behavior invariants

| ID | Invariant |
|---|---|
| B-001 | First overlap for a given (file, peer-session) → full `[W-14]` warning with FIX block, `vg_log` warn event (current behavior). |
| B-002 | Subsequent overlap for the same (file, peer-session) within the cooldown window → no agent-visible warning; an `info`-level `w14 overlap suppressed (cooldown)` event is still appended to events.jsonl. |
| B-003 | Cooldown window is config-driven: `VIBEGUARD_W14_COOLDOWN_SECONDS` env / `w14.cooldown_seconds` runtime-config key, default 3600; value 0 disables suppression (restores current behavior — U-32 downgrade path). |
| B-004 | A different peer session or different file always warns fully, regardless of cooldown state. |
| B-005 | Cooldown state survives across hook invocations within a session and is stored under the project state dir; corrupt/missing state degrades to "no suppression" (fail-open to warning, never to silence). |
| B-006 | Rust path and shell fallback produce equivalent decisions on the shared fixture set. |

## Design

- **State**: derive suppression from the event log itself where possible — `detect_w14` already reads recent events; check whether a `w14 overlap recent session <S>` warn for the same file + peer session exists within `cooldown_seconds` before emitting. This avoids a new state file (B-005 falls out of existing event-append durability). If event-scan cost is a concern, bound the scan to the existing `recent_overlap` event slice.
- **Rust**: extend `detect_w14` (`hook_orchestrator_post_edit_history.rs:101`) with the prior-warn lookup + config read via the existing `runtime_config_int_value` helper (same pattern as `hook_orchestrator.rs:494-496`).
- **Shell**: mirror in `vg_post_edit_detect_w14_overlap` (`post_edit_history.sh:139`) with a grep over the tail of the project events file.
- **Suppressed event shape**: `decision=info`, reason `w14 overlap suppressed (cooldown) session <S>`, so `scripts/stats.sh` and the GC learn digest can still count raw overlap frequency.

## Product-to-test mapping

| Behavior invariant | Implementation area | Verification |
|---|---|---|
| B-001, B-002, B-004 | `detect_w14` in `hook_orchestrator_post_edit_history.rs` | Rust unit tests: event fixtures (first hit / repeat-within-window / repeat-other-session) assert warning presence + suppressed info event |
| B-003 | config read | test with `VIBEGUARD_W14_COOLDOWN_SECONDS=0` asserts every repeat warns |
| B-005 | prior-warn lookup | fixture with truncated/corrupt events line → full warning emitted (fail-open) |
| B-006 | `hooks/_lib/post_edit_history.sh` | shared shell contract test (`tests/` post-edit history suite) runs the same three fixtures against the shell path |

## Verification plan

- `cargo test -p vibeguard-runtime` (new detect_w14 cases) and the existing shell hook test suite in CI.
- Manual: two parallel sessions editing one file — second and later edits within an hour produce exactly one visible W-14 warning per session pair.

## Rollback

Config default `w14.cooldown_seconds=0` can neutralize the feature without code rollback; otherwise revert the single commit (Rust + shell + tests).
