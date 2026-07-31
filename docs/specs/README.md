# VibeGuard Specs Index

This directory holds maintainer-facing specs. Most files here are implementation evidence or scoped design contracts, not a raw backlog. Before opening new work, check the status below and verify linked issues or PRs.

## Current Specs

| Spec | Status | Use it for |
|---|---|---|
| `GH703/` | Draft | Privacy-safe default weekly value summaries, taxonomy accounting, scheduler lifecycle, and explicit share exports |
| `GH720/` | Historical optional-tooling reference | Former automatic stage-aware packet validation, retained for explicitly invoked offline SpecRail checks |
| `GH699/` | Draft | Clone-free installation through verified release payloads and Homebrew/npm entry points |
| `GH701/` | Draft | Versioned host-adapter seam, real third-host proof, and dependency-gated agent-firewall positioning |
| `GH700/` | Draft | Public reproducible effectiveness benchmarks with provenance, ground truth, precision, and latency contracts |
| `GH702/` | Draft | Published third-party guard-pack contracts, transactional lifecycle, supply-chain trust, and precision-gated defaults |
| `GH706/` | Draft | Privacy-safe malformed-input diagnostics and shared protocol-error versus rule-interception block counts |
| `GH719/` | Draft | Persistent per-skill opt-out for managed Codex/Claude skill copies, with reported rather than silent restores |
| `GH704/` | Draft | Opt-in L2 semantic checks, named runtime W-rule deltas, structured precision evidence, and human-gated cross-session learning |
| `GH686/` | Implemented reference | Paired with/without evaluation for prompt-injected rule target improvement and non-target regression evidence (#686 / PR #696) |
| `GH687/` | Implemented reference | W-21 evidence-provenance rule plus the W-01 channel-trust step 0 |
| `GH675/` | Implemented reference | Manual precision-triage capture, empty-channel visibility, and the documented feedback loop |
| `GH671/` | Implemented reference | Baseline-aware U-16 enforcement for legacy oversized files plus staged/CI changed-file checks |
| `GH659/` | Implemented reference | Bound wrapper/event log growth, stale learning markers, and scheduled oversized-scan status |
| `GH661/` | Implemented reference | Preserve wrapped-hook exit code, conventional signal decoding, and nonempty failure evidence |
| `GH660/` | Implemented reference | Retirement of the strategic-compact skill and stale claude-md-split skill-name references |
| `GH658/` | Implemented reference | Required work-surface classification before readiness routing |
| `GH652/` | Implemented reference | Deterministic current-source runtime build and pinning before setup structured-report assertions |
| `GH631/` | Implemented reference | Explicit orphan deletion, maintainer-only sgconfig discovery, and fail-visible distribution asset inventory |
| `GH630/` | Implemented reference | Pinned Claude eval aliases, UTC-bounded offline freshness evidence, and one shared model-resolution contract |
| `GH629/` | Implemented reference | Fail-visible, schema-backed user runtime config validation with complete getter/template inventory |
| `GH628/` | Implemented reference | Git-tracked Markdown personal-path detection and strict, scoped doc-path allowlist freshness |
| `GH627/` | Implemented reference | Closed-map resolution of Codex namespaced hook names to canonical hook files without physical alias shells |
| `GH626/` | Implemented reference | Canonical-source generation and freshness enforcement for the compact injected rule table |
| `GH632/` | Implemented reference | Repository map, site version copy, and stale presentation metadata refresh |
| `GH644/` | Implemented reference | Deterministic stdin and complete child-error evidence for runtime-policy expected-error integration tests |
| `GH615/` | Implemented reference | Reminder-aware pre-write escalation counting, same-session Grep/Glob recovery, and actionable block guidance |
| `GH623/` | Implemented reference | Behavior-preserving decomposition of the oversized self-application CI harness into ordered focused test domains |
| `GH621/` | Implemented reference | Behavior-preserving extraction of install-time runtime acquisition, provenance, and source fallback from the oversized setup entrypoint |
| `codex-app-observability-plugin.md` | Implemented reference | Codex App plugin packaging, dashboard generation, observability commands, and plugin privacy boundaries |
| `GH618/` | Implemented reference | Manifest-driven compliance language scope, guard-pack reporting, and fail-visible config handling |
| `GH614/` | Implemented reference | Bounded macOS CI timeout headroom while preserving required check names and blocking setup coverage |
| `GH611/` | Implemented reference | Stable multi-sample hook P95 latency gate replacing the flaky 3-sample max collapse |
| `GH608/` | Implemented reference | Correct default `VIBEGUARD_DIR` resolution for standalone compliance-check runs |
| `GH605/` | Implemented reference | Rust test-path classifier recognition of `*_tests.rs` for RS-03 precision |
| `GH581/` | Implemented reference | Rust coverage ratchets from a latest-head clean measurement through risk-ordered, independently reviewed tranches to the enforced 80% gate |
| `GH588/` | Implemented reference | Scheduled GC execution freshness, platform-correct wrapper/internal log evidence, and preserved setup-check mode semantics |
| `GH589/` | Implemented reference | Repo-scoped code-slop self-scan precision for Rust CLI stdout and line-scoped detector pattern sources |
| `GH590/` | Implemented reference | Directed session-pair W-14 cooldown, fail-open bounded history, schema-valid suppression telemetry, and runtime config distribution |
| `GH595/` | Historical optional-tooling reference | Original SpecRail adoption and offline gate design, retained as reference rather than repository authorization |
| `GH556/` | Implemented reference | Weekly health report for rule trigger counts, precision risk, unclassified backlog, idle asset detection, and opt-in scheduling |
| `GH566/` | Implemented reference | Codex unmanaged stale `PreToolUse` hook detection, explicit repair, and setup-test fixture isolation |
| `GH551/` | Implemented reference | Hook hot-path collapse into a single vibeguard-runtime invocation to cut fork latency |
| `GH543/` | Implemented reference | Symmetric `--clean` removal of `~/.vibeguard` and installed git-hook symlinks |
| `GH542/` | Implemented reference | Stale installed-snapshot drift warning after `git pull` |
| `GH541/` | Implemented reference | Default Claude profile compact rule injection within the U-32 constraint budget |
| `GH540/` | Implemented reference | Guard triage capture wiring so the precision scorecard accumulates real TP/FP data |
| `GH539/` | Implemented reference | Claude wrapper fail-closed on policy/config errors, matching the Codex wrapper |
| `install-friction-reduction.md` | Implemented reference | Prebuilt runtime binaries, release checksums, source-build fallback, and scheduler opt-in behavior |
| `learn-first-class-signal-inbox.md` | Implemented reference | Learn signal inbox, signal classification, triage state, adoption compiler, and outcome evaluator planning |
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
