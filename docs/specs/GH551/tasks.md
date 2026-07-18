# Task Plan

## Linked Issue

GH-551

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP551-T1` Owner: agent — Fix runtime binary resolution order in `hooks/log.sh` so release is preferred over debug, keeping `VIBEGUARD_RUNTIME` override first. Done when: with both builds present the release path is selected. Verify: resolution-order unit case added to `tests/test_hooks.sh` passes.
- [ ] `SP551-T2` Owner: agent — Add the `hook <name>` orchestrator scaffold to `vibeguard-runtime/src/main.rs`: stdin intake, env-override contract, project-hash via in-process SHA-256 (reuse `vibeguard-runtime/src/git_root.rs`), native `duration_ms`, and in-process dual JSONL append through `vibeguard-runtime/src/log_append.rs`. Done when: a no-op hook subcommand reads stdin and writes both event logs with the current schema. Verify: `cargo test --manifest-path vibeguard-runtime/Cargo.toml` new orchestrator tests pass and `tests/test_observability_schemas.sh` passes.
- [ ] `SP551-T3` Owner: agent — Port session/CLI inference from `hooks/_lib/log_session.sh` into the runtime (ancestor walk, 30-minute session-file reuse, unknown-caller rule) with env overrides taking precedence. Done when: same inputs produce the same session grouping and caller fields as the bash path. Verify: runtime unit tests covering claude/codex/unknown parents and session reuse window pass.
- [ ] `SP551-T4` Owner: agent — Migrate `hooks/pre-write-guard.sh` to a thin wrapper around `vibeguard-runtime hook pre-write`, folding in breaker calls via `vibeguard-runtime/src/circuit_breaker.rs` and the U-16/W-12/L1 decision matrix with byte-identical output. Done when: golden parity fixtures (pass/warn/block/escalate/malformed) show identical stdout and exit codes old-vs-new. Verify: new parity test plus `tests/test_hooks.sh` pass; `tests/bench_hook_latency.sh` pre-write P95 under budget and below current baseline.
- [ ] `SP551-T5` Owner: agent — Migrate `hooks/stop-guard.sh` and `hooks/pre-bash-guard.sh` onto their runtime orchestrators using the T2/T3 plumbing. Done when: parity fixtures for both hooks are identical old-vs-new. Verify: `tests/test_hooks.sh` and `tests/bench_hook_latency.sh` budgets pass for both hooks.
- [ ] `SP551-T6` Owner: agent — Migrate the remaining configured hooks (`hooks/learn-evaluator.sh`, `hooks/pre-edit-guard.sh`, `hooks/post-edit-guard.sh`, `hooks/post-write-guard.sh`) and delete the bash logging/breaker code paths that no longer have callers (no aliases kept). Done when: no configured hook sources the removed bash paths and all hooks meet budget. Verify: full `tests/test_hooks.sh`, `tests/test_hook_perf_contract.sh`, and grep shows no remaining callers of removed functions.
- [ ] `SP551-T7` Owner: human — Review decision-string parity evidence and CI Hook Latency (P95) trend across the migration PRs before enabling the tightened budgets. Done when: maintainer approves the parity report and budget change. Verify: PR review approval recorded.

## Parallelization

- T1 is independent and can land first.
- T2 and T3 are shared runtime plumbing (single owner: `vibeguard-runtime/src/`); T4-T6 depend on them.
- T4, T5, T6 each own disjoint hook script files plus their fixtures; run sequentially or in parallel lanes with per-hook file ownership (W-14).
- T7 gates the final budget tightening.

## Verification

- Per migrated hook: golden parity fixture diff (old bash path vs runtime path, same stdin) is empty for pass/warn/block/escalate/malformed cases.
- `tests/bench_hook_latency.sh` and `tests/test_hook_perf_contract.sh` pass with migrated hooks under per-hook budgets; judge on the CI benchmark trend, not one local sample.
- `tests/test_observability_schemas.sh` validates event lines emitted by the runtime path.
- One live session smoke: Write + Bash + Stop through `hooks/run-hook.sh`, then inspect the project and global `events.jsonl` for schema, session continuity, and caller fields.

## Handoff Notes

- Decision strings are load-bearing: agents and tests parse them, so parity is byte-level, not semantic. Never "improve" a message during migration.
- The env-override contract (`VIBEGUARD_LOG_FILE`, `VIBEGUARD_SESSION_ID`, etc. take precedence over recomputation) is what keeps benchmarks and the codex app-server wrapper isolated — preserve it in the runtime orchestrator.
- Warn-mode policy downgrade happens in `hooks/run-hook.sh` on the wrapper's stdout; the runtime must keep block decisions on stdout so the downgrade path still sees them.
- Fail-closed is the default everywhere: runtime missing, breaker state unreadable, malformed stdin all block with explicit messages.
- Measured baseline for this spec: full pre-write hook ~350ms locally (CI P95 556ms) vs ~4ms for the runtime check alone; the gap is bash fork overhead (`git rev-parse` + `shasum` ~70ms, `ps` walks, `perl`/`date` forks, ~48 command substitutions in `hooks/circuit-breaker.sh`).
