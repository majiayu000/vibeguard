# Agent Instructions

## Scope

This file applies to the whole repository unless a nested `AGENTS.md` overrides it.

VibeGuard is an anti-hallucination rules, hooks, runtime, installer, and workflow repository. There is no ORM, front-end framework, or microservices layer in this project.

## Start Here

1. Check the worktree with `git status --short --branch`.
2. Search before adding files, functions, rules, hooks, workflows, or tests.
3. Read `docs/directory-map.md` before moving files or changing public paths.
4. Read `docs/specs/README.md` before treating a spec as pending work.
5. Read `plan/README.md` before treating files under `plan/` as active backlog.
6. For runtime, hook, setup, or workflow changes, read the closest scoped `CLAUDE.md` in that subtree.
7. For GitHub issue or PR work, read `AGENT_USAGE.md`, `workflow.yaml`, `states.yaml`, `labels.yaml`, and `skills/specrail-workflow/SKILL.md`.

## Core Rules

- Keep names `snake_case` unless an external API boundary requires `camelCase`.
- Do not swallow errors silently. User-visible missing data or wrong output must fail loudly.
- Do only the requested scope; avoid opportunistic refactors.
- Preserve VibeGuard's core enforcement model: rules, hooks, setup scripts, and `vibeguard-runtime/` are the source implementation.
- Treat plugin, pack, docs, and workflow changes as distribution layers unless a spec explicitly changes runtime behavior.
- High-context files such as `AGENTS.md`, `CLAUDE.md`, `.claude/settings*.json`, setup scripts, hooks, and workflow contracts must not be modified by generated output without explicit intent.
- Never add AI-generated markers or hidden attribution text to commits, docs, or generated artifacts.

## Routing

Follow `workflows/references/routing-contract.md` for non-trivial work.

Classify `work_surface` as `code_execution`, `writing_research`, or
`chat_support` through the exact `precedence` ladder before setting `readiness` to `execute_direct`, `plan_first`, or
`clarify_first`. If classification lacks or finds conflicting facts, clarify
before emitting a routing decision; downstream consumers must not reclassify
the surface locally.

| Change | Default readiness |
|---|---|
| Focused docs or test-only cleanup | `execute_direct` |
| Small bug with clear reproduction and local test | `execute_direct` |
| Runtime, hook, setup, policy, schema, or installer change | `plan_first` |
| Ambiguous behavior, missing done-when, or conflicting specs | `clarify_first` |
| Generated surface or high-context file rewrite | `plan_first` |

`plan_first` handoffs must always carry `mode`, `artifacts`, `runtime_pinning_snapshot`, `verification_owner`, `stop_conditions`, and `lane_map`; use `None` or a minimal value when a field does not otherwise apply.

## SpecRail Adoption

- SpecRail packets use `docs/specs/GH<number>/`; do not create a second `specs/` root.
- Persisted `automation_policy.auth_mode` remains `review`. An explicit `implx auto` invocation is transient authorization for that run only.
- Automation authorization never bypasses `checks/pr_gate.py`, `checks/runtime_ledger_gate.py`, CI, review-thread, or merge-state evidence.
- The adopted source commit and consumer overrides are recorded in `AGENT_USAGE.md`.

## Repository Map

- `rules/claude-rules/`: canonical native rule source.
- `hooks/`: installed hook scripts and adapters.
- `guards/`: universal and language-specific guard scripts.
- `vibeguard-runtime/`: Rust runtime for hook-side JSON, metrics, package rewrite logic, and Codex app-server wrapper.
- `scripts/setup/` and `setup.sh`: public setup entrypoints.
- `scripts/ci/`: CI contract validators.
- `tests/`: shell and Rust regression coverage for hooks, setup, workflows, and contracts.
- `skills/`, `workflows/`, `agents/`, `.claude/commands/`: shipped agent workflow surfaces.
- `plugins/vibeguard/`: Codex App plugin wrapper and observability commands.
- `docs/specs/`: maintainer specs with status index.
- `plan/`: workflow output and historical execution plans; not all files are active backlog.

## Spec And Plan Gate

| Situation | Required context |
|---|---|
| New user-facing behavior or policy semantics | Add or update a spec under `docs/specs/` or `plan/` first |
| Work on existing spec | Check `docs/specs/README.md` for status and linked issue state |
| Work on existing plan | Check `plan/README.md` for active, draft, historical, or snapshot status |
| Rust-only production path | Start with `docs/specs/rust-only-production-path.md` and `plan/2026-06-05_22-28-rust-only-production-path.md` |
| Codex plugin or dashboard | Start with `docs/specs/codex-app-observability-plugin.md` and `plugins/vibeguard/README.md` |
| Install friction, release binaries, scheduler defaults | Start with `docs/specs/install-friction-reduction.md` |

If code and an older spec disagree, verify the current implementation before changing either. Update the spec index when a draft becomes implemented or obsolete.

## High-Risk Areas

- Runtime policy and fail-closed behavior in `vibeguard-runtime/` and `hooks/_lib/`.
- Setup writes to user high-context files under Claude, Codex, Git hooks, or VibeGuard config.
- Manifest and schema contracts under `schemas/`, `hooks/manifest.json`, and workflow references.
- Generated rule documentation and canonical rule language.
- Shared local setup state touched by `tests/test_setup.sh`.
- Plugin manifests, marketplace metadata, and install-surface assets.

## Validation

Before completion, run the focused command that proves the changed surface. Before submission, run the relevant gate from this table.

| Changed surface | Commands |
|---|---|
| Rust runtime | `cargo check --manifest-path vibeguard-runtime/Cargo.toml` and `cargo test --manifest-path vibeguard-runtime/Cargo.toml` |
| Hooks or guard behavior | `bash scripts/ci/validate-hooks.sh`, `bash scripts/ci/validate-hooks-manifest.sh`, and the focused test under `tests/hooks/` or `tests/codex_runtime/` |
| Setup or installed hook state | `bash tests/test_setup.sh` and the focused setup test |
| Manifest, schema, routing, or workflow contracts | `bash tests/test_manifest_contract.sh` and `bash tests/test_workflow_contracts.sh` |
| Skills or workflows | `bash scripts/ci/validate-skill-format.sh` and `bash scripts/ci/validate-workflow-contracts.sh` |
| Documentation paths or commands | `bash scripts/ci/validate-doc-paths.sh` and `bash scripts/ci/validate-doc-command-paths.sh` |
| Rule docs or rule IDs | `bash scripts/ci/validate-rules.sh`, `bash scripts/ci/validate-generated-rule-docs.sh`, and `bash scripts/verify/doc-freshness-check.sh --strict` |

Run `bash scripts/local-contract-check.sh --quick` for a broad local contract pass when the change crosses multiple surfaces. If a validation command cannot run, report the exact blocker instead of claiming completion.
