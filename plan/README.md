# VibeGuard Plan Index

`plan/` is the workflow output directory. It contains completed execution records, active plans, draft specs, snapshots, and signal reports. Do not treat every file here as active backlog.

## Status Classes

| Class | Meaning | Files |
|---|---|---|
| Active execution plan | Current multi-step work where remaining steps may still be actionable after checking linked issues and main branch | `2026-06-05_22-28-rust-only-production-path.md` |
| Completed record | Historical execution evidence; use for context, not new scope | `2026-05-01_18-56-41-vibeguard-audit-remediation.md`, `spec-codebase-audit-remediation.md` |
| Historical convergence plan | Older architecture plan; verify current code and newer specs before acting | `2026-04-19_00-15-39-main-architecture-convergence.md` |
| Draft spec | Candidate work that needs issue and code-state verification before implementation | `spec-app-server-runtime-policy-gate.md`, `spec-posttool-malformed-input-fail-visible.md`, `spec-runtime-config-contract-clarity.md`, `spec-test-file-size-decomposition.md`, `spec-96-prompt-contract-schema.md`, `full-english-localization-spec.md` |
| Snapshot or signal report | Evidence artifact for another plan or issue; do not implement directly without an owning spec | `w20-rust-only-production-path-snapshot.md`, `signal-report-legacy-vibeguard-mcp-cleanup.md` |

## Reading Rules

- Start with `docs/specs/README.md` for specs that have moved into the maintained specs directory.
- Verify linked GitHub issues before acting on any draft or active plan.
- For completed records, prefer current code, tests, and merged PRs over old wording.
- Do not move `plan/` files unless the plan workflow contract changes.
- Keep new plan files focused on one execution lane and include explicit stop conditions and validation commands.

## When To Add A New Plan

Add a plan when work is multi-step, crosses runtime/setup/workflow boundaries, or changes fail-closed semantics. Small documentation edits, focused test fixes, and narrow bug fixes can execute directly when the root cause and validation command are clear.

## Validation For Plan Edits

Run these checks for documentation-only plan edits:

```bash
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```

If the plan edit changes workflow routing, also run:

```bash
bash scripts/ci/validate-workflow-contracts.sh
bash tests/test_workflow_contracts.sh
```
