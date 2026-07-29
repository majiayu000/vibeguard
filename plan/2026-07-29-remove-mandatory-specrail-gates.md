# Remove Mandatory SpecRail Gates

Status: Active execution plan

Linked issue: [#722](https://github.com/majiayu000/vibeguard/issues/722)

Base: `origin/main@05ca05e0030897ea8e8585c0eacb62c7d12185d9`

## Goal

Remove automatic and mandatory repository-level SpecRail gates while retaining
optional offline SpecRail tooling and all ordinary VibeGuard quality,
runtime, hook, guard, setup, release, and security enforcement.

## Scope

- Delete the SpecRail PR/push workflow.
- Move its generic `git diff --check` protection into ordinary CI without
  changing the protected OS job names.
- Make root repository instructions use live GitHub state, isolated worktrees,
  current-head CI, independent review, review-thread state, and merge state.
- Make SpecRail checks, configs, templates, schemas, packets, and skills
  explicitly invoked optional tools.
- Keep focused smoke coverage for those offline tools and assert that no
  GitHub workflow invokes them automatically.

## Non-Goals

- Do not remove or weaken VibeGuard runtime, hooks, guards, setup, release,
  manifest, schema, documentation, coverage, precision, or security checks.
- Do not delete SpecRail checkers, evidence adapters, configs, templates,
  schemas, skills, or historical spec packets.
- Do not rename `CI (ubuntu-latest)`, `CI (macos-latest)`, or
  `CI (windows-latest)`.
- Do not modify branch protection, force push, or merge without explicit human
  authorization.

## Stop Conditions

- `origin/main` advances in an overlapping instruction, workflow, or test
  surface.
- Completion requires an edit outside the issue #722 owned paths.
- A test failure requires weakening ordinary VibeGuard enforcement.
- Live GitHub evidence disagrees with the pinned base or linked issue scope.

## Implementation

- [x] Remove the automatic SpecRail workflow.
- [x] Move changed-file whitespace validation into ordinary CI.
- [x] Reframe root agent guidance and SpecRail usage as explicit opt-in.
- [x] Preserve and retest optional offline SpecRail tooling.
- [x] Reclassify GH595 and GH720 as historical optional-tooling references.
- [x] Run focused and broad local verification.
- [ ] Obtain independent review and fresh CI for the linked PR head.

## Verification

```bash
git diff --check origin/main...HEAD
bash tests/test_specrail_adoption.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
bash scripts/ci/validate-skill-format.sh
bash tests/test_distribution_assets.sh
bash scripts/ci/validate-specs-index.sh
bash tests/test_workflow_contracts.sh
bash scripts/ci/validate-workflow-contracts.sh
bash scripts/local-contract-check.sh --quick
```

Fresh GitHub CI must pass on the linked PR head before merge readiness is
reported.
