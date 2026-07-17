# VibeGuard Specs Index

This directory holds maintainer-facing specs. Most files here are implementation evidence or scoped design contracts, not a raw backlog. Before opening new work, check the status below and verify linked issues or PRs.

## Current Specs

| Spec | Status | Use it for |
|---|---|---|
| `GH631/` | Draft | Explicit orphan deletion, maintainer-only sgconfig discovery, and fail-visible distribution asset inventory |
| `GH630/` | Implemented reference | Pinned Claude eval aliases, UTC-bounded offline freshness evidence, and one shared model-resolution contract |
| `GH629/` | Implemented reference | Fail-visible, schema-backed user runtime config validation with complete getter/template inventory |
| `GH628/` | Implemented reference | Git-tracked Markdown personal-path detection and strict, scoped doc-path allowlist freshness |
| `GH627/` | Implemented reference | Closed-map resolution of Codex namespaced hook names to canonical hook files without physical alias shells |
| `GH626/` | Implemented reference | Canonical-source generation and freshness enforcement for the compact injected rule table |
| `GH644/` | Draft | Deterministic stdin and complete child-error evidence for runtime-policy expected-error integration tests |
| `GH615/` | Draft | Reminder-aware pre-write escalation counting, same-session Grep/Glob recovery, and actionable block guidance |
| `GH623/` | Draft | Behavior-preserving decomposition of the oversized self-application CI harness into ordered focused test domains |
| `GH621/` | Draft | Behavior-preserving extraction of install-time runtime acquisition, provenance, and source fallback from the oversized setup entrypoint |
| `codex-app-observability-plugin.md` | Draft implementation | Codex App plugin packaging, dashboard generation, observability commands, and plugin privacy boundaries |
| `GH618/` | Draft | Manifest-driven compliance language scope, guard-pack reporting, and fail-visible config handling |
| `GH614/` | Draft | Bounded macOS CI timeout headroom while preserving required check names and blocking setup coverage |
| `GH581/` | Implemented reference | Rust coverage ratchets from a latest-head clean measurement through risk-ordered, independently reviewed tranches to the enforced 80% gate |
| `GH588/` | Draft | Scheduled GC execution freshness, platform-correct wrapper/internal log evidence, and preserved setup-check mode semantics |
| `GH589/` | Draft | Repo-scoped code-slop self-scan precision for Rust CLI stdout and line-scoped detector pattern sources |
| `GH590/` | Draft | Directed session-pair W-14 cooldown, fail-open bounded history, schema-valid suppression telemetry, and runtime config distribution |
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
