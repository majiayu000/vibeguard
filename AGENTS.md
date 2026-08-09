# Agent Instructions

## Scope

This file applies to the whole repository unless a nested `AGENTS.md` overrides it.

VibeGuard is an anti-hallucination rules, hooks, runtime, installer, and workflow repository. There is no ORM, front-end framework, or microservices layer in this project.

## Start Here

1. Check `git status --short --branch` and preserve unrelated work.
2. Search before adding files, functions, rules, hooks, workflows, or tests.
3. Read `docs/directory-map.md` before moving files or changing public paths.
4. Read `docs/specs/README.md` and `plan/README.md` before treating documents as pending work.
5. For runtime, hook, setup, or workflow changes, read the closest scoped `CLAUDE.md`.
6. For GitHub work, verify live remote state and use an isolated worktree based on the current remote base.

## Core Rules

- Keep names `snake_case` unless an external API boundary requires `camelCase`.
- Do not swallow errors silently. User-visible missing data or wrong output must fail loudly.
- Do only the requested scope; avoid opportunistic refactors.
- Preserve VibeGuard's core enforcement model: rules, hooks, setup scripts, and `vibeguard-runtime/` are the source implementation.
- Treat plugin, pack, docs, and workflow changes as distribution layers unless a current design explicitly changes runtime behavior.
- High-context files such as `AGENTS.md`, `CLAUDE.md`, `.claude/settings*.json`, setup scripts, hooks, and workflow contracts require explicit intent.
- Never add AI-generated markers or hidden attribution text to commits, docs, or generated artifacts.

## Delivery Policy

- Implement clear, bounded tasks directly. Do not require a spec, routing packet, schema, receipt, runtime snapshot, or multi-agent handoff for ordinary work.
- Clarify only when a missing choice would materially change the result or make execution unsafe.
- Write a plan for major architecture, migration, cross-system policy work, or when the user explicitly requests one.
- A normal spec is at most two files and about 300 lines total. Docs-only changes, small bugs, and explicit mechanical edits are spec-exempt.
- Do not create validators for spec validators or add process artifacts merely to satisfy another process artifact.
- Use focused tests while iterating. Run the broader relevant suite before submission; leave exhaustive platform coverage to CI.

## Session And Review Limits

- At most one writable session may operate on this repository at a time. Read-only helpers are allowed only when useful and explicitly scoped.
- Keep one issue in one short session. Stop and hand off before repeated compaction or an unbounded queue drain.
- Do not delegate by default. Use another agent only when the user explicitly asks or a major task has genuinely independent ownership.
- A PR gets at most two review rounds initiated by this workflow.
- When review reports `Findings: 0` and `PASS`, stop immediately.
- If code and tests pass but a process-only gate remains unmet, hand the decision to a human; do not manufacture more documents or review loops.

## GitHub Safety

- Search live issues, PRs, branches, CI, and review threads before creating competing work.
- Keep remote truth separate from local worktree state.
- Merge-readiness evidence must use the current head SHA, required CI, unresolved review-thread state, and merge state.
- Never merge, change repository permissions, force push, close disputed work, or publish private security details without explicit human authorization.

## Repository Map

- `rules/claude-rules/`: canonical native rule source.
- `hooks/`: installed hook scripts and adapters.
- `guards/`: universal and language-specific guard scripts.
- `vibeguard-runtime/`: Rust runtime for hook-side JSON, metrics, package rewrite logic, and the Codex app-server wrapper.
- `scripts/setup/` and `setup.sh`: public setup entrypoints.
- `scripts/ci/`: CI contract validators.
- `tests/`: shell and Rust regression coverage.
- `skills/`, `workflows/`, `agents/`, `.claude/commands/`: shipped agent workflow surfaces.
- `plugins/vibeguard/`: Codex App plugin wrapper and observability commands.
- `docs/specs/`: maintainer design history and explicitly selected current specs; it is not an automatic backlog.
- `plan/`: mixed workflow output and historical execution plans; it is not an automatic backlog.

## High-Risk Areas

- Runtime policy and fail-closed behavior in `vibeguard-runtime/` and `hooks/_lib/`.
- Setup writes to user high-context files under Claude, Codex, Git hooks, or VibeGuard config.
- Manifest and schema contracts under `schemas/`, `hooks/manifest.json`, and workflow references.
- Generated rule documentation and canonical rule language.
- Shared local setup state touched by `tests/test_setup.sh`.
- Plugin manifests, marketplace metadata, and install-surface assets.

## Validation

Before completion, run the focused command that proves the changed surface. Before submission, run the relevant gate.

| Changed surface | Commands |
|---|---|
| Rust runtime | `cargo check --manifest-path vibeguard-runtime/Cargo.toml` and `cargo test --manifest-path vibeguard-runtime/Cargo.toml` |
| Hooks or guards | `bash scripts/ci/validate-hooks.sh`, `bash scripts/ci/validate-hooks-manifest.sh`, and focused tests |
| Setup | Focused setup test locally; `bash tests/test_setup.sh` before submission when feasible; full platform matrix in CI |
| Manifest or workflow contracts | `bash tests/test_manifest_contract.sh` and `bash tests/test_workflow_contracts.sh` |
| Skills or workflows | `bash scripts/ci/validate-skill-format.sh` and `bash scripts/ci/validate-workflow-contracts.sh` |
| Documentation | `bash scripts/ci/validate-doc-paths.sh` and `bash scripts/ci/validate-doc-command-paths.sh` |
| Rules | `bash scripts/ci/validate-rules.sh`, `bash scripts/ci/validate-generated-rule-docs.sh`, and `bash scripts/verify/doc-freshness-check.sh --strict` |

Run `bash scripts/local-contract-check.sh --quick` for a broad local pass when a change crosses multiple surfaces. Report exact blockers instead of claiming unrun checks passed.
