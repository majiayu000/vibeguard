# Sprint Plan: Issues #28, #29, #30, #31

Date: 2026-03-24
Repo: `majiayu000/vibeguard`

## Signal Report (Diagnose Before Fix)

### Issue #31 — Claude Code `updatedInput` transparent correction instead of block+retry
- State: OPEN
- Root cause: PreToolUse hooks currently rely on `block`/`warn` responses and do not emit `updatedInput` corrections for mechanical rewrites.
- Evidence in code:
  - `hooks/pre-bash-guard.sh` only returns `{"decision":"block"}` or `{"decision":"warn"}` payloads.
  - No `updatedInput` usage found in hooks/tests (`rg updatedInput` in repo code paths).
- Primary files likely touched:
  - `hooks/pre-bash-guard.sh`
  - `hooks/pre-write-guard.sh`
  - `hooks/pre-edit-guard.sh`
  - `tests/test_hooks.sh`

### Issue #30 — Baseline scanning: only warn on new issues
- State: OPEN
- Root cause: pre-commit includes staged-file filtering, but multiple guards still scan full staged files (not added lines), and full-project baseline mode (`--baseline <commit>`) is not implemented.
- Evidence in code:
  - `hooks/pre-commit-guard.sh` exports staged files but does not provide a baseline commit mechanism.
  - `guards/typescript/check_any_abuse.sh`, `guards/typescript/check_console_residual.sh`, and Go guards run line scans on full files.
  - No `--baseline` support found in scripts/guards.
- Primary files likely touched:
  - `hooks/pre-commit-guard.sh`
  - `guards/rust/common.sh` and Rust guard scripts
  - `guards/typescript/common.sh` and TS guard scripts
  - `guards/go/common.sh` and Go guard scripts
  - Python guard scripts invoked in pre-commit/check flows
  - `tests/test_hooks.sh`

### Issue #29 — Suppression comments: `// vibeguard-disable-next-line`
- State: OPEN
- Root cause: there is currently no suppression parser/check in guard scripts; no rule-scoped inline disable behavior exists.
- Evidence in code:
  - No `vibeguard-disable-next-line` handling in hooks/guards/tests (`rg` has no matches).
- Primary files likely touched:
  - Guard scripts that emit line-based findings across `guards/rust`, `guards/typescript`, `guards/go`, `guards/python`
  - Shared guard utilities (for suppression parsing)
  - `tests/test_hooks.sh` and/or new guard tests

### Issue #28 — 9 known false positives remain unfixed
- State: OPEN
- Root cause: known regex/heuristic limits are documented and still marked pending.
- Evidence in code/docs:
  - `docs/known-issues/false-positives.md` lists all 9 items as `待修`.
  - Affected scripts match the issue backlog table entries.
- Primary files likely touched:
  - `guards/rust/check_unwrap_in_prod.sh` (RS-03)
  - `guards/rust/check_nested_locks.sh` (RS-01)
  - `guards/rust/check_workspace_consistency.sh` (RS-06)
  - `guards/rust/check_single_source_of_truth.sh` (RS-12)
  - `guards/rust/check_taste_invariants.sh` (TASTE-ASYNC-UNWRAP)
  - `hooks/post-write-guard.sh`
  - `hooks/post-build-check.sh`
  - `hooks/pre-bash-guard.sh` (doc-file-blocker path matching)
  - `docs/known-issues/false-positives.md`

## Dependency Graph Rationale
- `#28` is P2 and has clear direct bug-fix scope; it should start immediately.
- `#30` and `#29` heavily overlap in guard scanning surfaces. Baseline/diff-aware scanning (#30) should land before suppression semantics (#29), so suppression logic is built on stable reporting boundaries.
- `#31` overlaps with `#28` on `hooks/pre-bash-guard.sh`; schedule `#31` after `#28` to avoid merge churn in low-priority work.
- No pending issue is skipped: none are already fixed, duplicate, or invalid based on current code + issue state.

SPRINT_PLAN_START
{
  "tasks": [
    {"issue": 28, "depends_on": []},
    {"issue": 30, "depends_on": [28]},
    {"issue": 31, "depends_on": [28]},
    {"issue": 29, "depends_on": [28, 30]}
  ],
  "skip": []
}
SPRINT_PLAN_END
