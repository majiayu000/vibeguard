# Delivery Base

Shared delivery rules for VibeGuard workflows.

## Start

- Confirm the requested outcome, scope, constraints, and done-when condition.
- Inspect the current worktree and preserve unrelated changes.
- Search for the existing implementation before adding a new surface.
- Execute a clear bounded task directly. Use a plan only for major architecture, migration, cross-system policy work, or explicit user requests.

## Specs And Plans

- Docs-only work, small bugs, and explicit mechanical changes are spec-exempt.
- A normal spec is at most two files and about 300 lines total.
- Do not add a task packet, schema, receipt, or validator merely because another process file expects one.
- Keep only one active implementation issue in the session.

## Execute

1. Reproduce or identify the current behavior.
2. Form one concrete hypothesis.
3. Make the smallest scoped change.
4. Run the smallest test that proves the behavior.
5. Run broader relevant checks before submission.

Do not mix unrelated cleanup into the change. After three failed fixes for the same problem, stop and challenge the hypothesis.

## Testing

- During iteration, run focused tests only.
- Before submission, run the relevant local build/test/contract checks.
- Leave exhaustive platform coverage and the full setup matrix to CI unless the changed behavior cannot be proven otherwise.
- Never weaken assertions or test infrastructure to make a failure disappear.

## Review Convergence

- Initiate at most two review rounds for one PR.
- `Findings: 0` plus `PASS` ends review immediately.
- Fix concrete correctness, security, or regression findings and rerun affected checks.
- If code and tests pass but a process-only gate remains unmet, hand the decision to a human. Do not create more documentation or another validator to satisfy it.

## Delegation

Follow [`delegation-contract.md`](delegation-contract.md) only when delegation is explicitly selected. One primary session remains responsible for integration and final verification.

## Handoff

Report the outcome, changed files, fresh validation evidence, and any real remaining blocker. Do not require a fixed handoff schema.
