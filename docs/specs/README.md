# VibeGuard Specs Index

This directory holds maintainer-facing specs. Most files here are implementation evidence or scoped design contracts, not a raw backlog. Before opening new work, check the status below and verify linked issues or PRs.

## Current Specs

| Spec | Status | Use it for |
|---|---|---|
| `codex-app-observability-plugin.md` | Draft implementation | Codex App plugin packaging, dashboard generation, observability commands, and plugin privacy boundaries |
| `GH581/` | Draft | Rust coverage ratchets from a latest-head clean measurement through risk-ordered, independently reviewed tranches to the enforced 80% gate |
| `GH595/` | Draft implementation | SpecRail repository adoption, configured VibeGuard overrides, offline PR/runtime gates, target-local evidence, and preserved human merge boundaries |
| `GH556/` | Implemented reference | Weekly health report for rule trigger counts, precision risk, unclassified backlog, idle asset detection, and opt-in scheduling |
| `GH566/` | Draft | Codex unmanaged stale `PreToolUse` hook detection, explicit repair, and setup-test fixture isolation |
| `install-friction-reduction.md` | Implemented reference | Prebuilt runtime binaries, release checksums, source-build fallback, and scheduler opt-in behavior |
| `learn-first-class-signal-inbox.md` | Draft | Learn signal inbox, signal classification, triage state, adoption compiler, and outcome evaluator planning |
| `rust-only-production-path.md` | Implemented reference | Python-free production path, Rust runtime boundaries, and remaining validation expectations |

## Reading Rules

- Treat `Status: Implemented` as current implementation context, not pending scope.
- Treat `Draft` as a design contract that still needs live code and issue verification before implementation.
- Keep linked issues and PRs in the spec when they are part of the execution contract.
- Do not move a spec into `docs/internal/` while active issues or public docs still point to it.
- Update this index when a spec is implemented, superseded, or split.

## Adjacent Planning Material

Execution plans and older draft specs live under `plan/`. Read `plan/README.md` before using those files as backlog. Some `plan/` files are completed records, snapshots, or signal reports rather than current work.

## Validation For Spec Edits

Run these checks for documentation-only spec edits:

```bash
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```

When a spec edit also changes workflows, manifests, runtime behavior, or setup behavior, run the corresponding commands from the top-level `AGENTS.md` validation table.
