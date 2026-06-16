# Spec: Rust-only production install and hook path

- Status: Implemented
- Date: 2026-06-05
- Owner: @majiayu000
- Readiness: execute_direct
- Severity: P1
- Related: `docs/specs/install-friction-reduction.md`, `scripts/setup/install.sh`, `scripts/setup/lib.sh`, `scripts/lib/install-state.sh`, `hooks/run-hook.sh`, `hooks/run-hook-codex.sh`, `hooks/_lib/policy.sh`, `hooks/_lib/codex_runner.sh`, `vibeguard-runtime/`

## Issue Tracking

- Umbrella: https://github.com/majiayu000/vibeguard/issues/371
- P1 runtime policy/config: https://github.com/majiayu000/vibeguard/issues/381
- P1 Codex normalization/adapters: https://github.com/majiayu000/vibeguard/issues/382
- P1 configured hook path: https://github.com/majiayu000/vibeguard/issues/383
- P2 setup/check/clean runtime migration: https://github.com/majiayu000/vibeguard/issues/384
- P2 no-Python CI/docs gate: https://github.com/majiayu000/vibeguard/issues/385
- Related app-server policy gate: https://github.com/majiayu000/vibeguard/issues/372

## Implementation Status

The production boundary in this spec is now enforced by tests:

- `tests/test_setup.sh` builds the debug runtime before creating fake release
  assets, so setup-flow release tests exercise real Rust setup commands.
- `tests/setup/install_flow_tests.sh` shadows `python3` and `python` with
  failing stubs and proves `setup.sh --yes --profile core`,
  `setup.sh --check --strict`, and `setup.sh --clean` complete without Python.
- `scripts/ci/self-application/check-hook-production-python-free.sh` remains
  the hook-path CI sentinel and is run by `scripts/ci/self-application/run-all.sh`
  in GitHub Actions.

This is a Python-free production path, not a Python-free repository. Eval,
documentation generation, developer validators, tests, and optional
language-specific guard tools may still use Python.

## 1. Problem

The release-binary install path removed the Rust/Cargo requirement for supported
platforms, but the production install and configured hook paths still require
Python. That keeps VibeGuard from being a single-runtime tool and preserves
avoidable hook latency from Python process startup.

This spec scopes the next migration target to a Python-free production path:

- `setup.sh` / `setup.sh --check` / `setup.sh --clean` on supported release
  targets.
- Configured Claude Code and Codex hooks in supported profiles.
- Runtime policy, config reads, Codex adaptation, apply_patch normalization,
  logging/status, and hook checks needed by the installed production path.

It does not require every repository script to be rewritten in Rust.

## 2. Verified Facts

Baseline captured from the `main` checkout on 2026-06-05 before this plan was
opened:

- The repo is on `900fd570807407133c0e2cc02bd756f84c7cd0a8`; the latest
  release tag is `v1.1.2`.
- `v1.1.2` publishes prebuilt `vibeguard-runtime` assets for macOS/Linux plus
  `SHA256SUMS`.
- `scripts/setup/install.sh` still fails if `python3` is unavailable.
- `scripts/setup/lib.sh` shells out to Python helpers for Claude settings,
  Codex hooks, Codex TOML config, manifest enumeration, and CLAUDE/AGENTS
  injection.
- `scripts/lib/install-state.sh` stores and checks install state through inline
  Python.
- `hooks/_lib/policy.sh` requires `vibeguard-runtime` for runtime policy,
  output downgrade, diagnostics, and visible failure payloads.
- `hooks/_lib/codex_runner.sh` requires
  `vibeguard-runtime codex-normalize-apply-patch`; there is no Python
  normalizer fallback.
- `hooks/pre-edit-guard.sh` already attempts `vibeguard-runtime pre-edit-check`
  first, but still contains an inline Python implementation for the full path.
- Baseline source inventory excluding `target`: 41 Rust files, 48 Python files,
  and 223 shell files.

The previous install-friction spec explicitly left single-runtime consolidation
as roadmap work. This spec promotes that roadmap item into an executable design.

## 3. Goals

- G1: On supported release targets, install, check, and clean complete without a
  `python3` executable in `PATH`.
- G2: Configured Claude Code and Codex hook paths do not invoke Python for
  policy, payload adaptation, apply_patch normalization, config reads, logging,
  status, or first-party guard checks.
- G3: Removing Python fallback is fail-closed. If the Rust runtime is missing,
  stale, or lacks a required subcommand, hooks produce visible failure instead of
  silently passing or falling back to a divergent implementation.
- G4: Shell wrappers remain thin compatibility entry points only. Business logic
  moves into `vibeguard-runtime`.
- G5: App-server, shell-wrapper, and native Codex hook paths share one Rust
  policy/config implementation.
- G6: Release assets remain integrity verified and version pinned.

## 4. Non-goals

- Full repository Rust rewrite. Eval, benchmark, docs generation, CI-only
  validators, and developer scripts may remain Python or shell.
- Rewriting optional language guard packs that intentionally inspect Python
  projects. Those may still require Python when the user enables or runs them.
- Removing shell bootstrap entirely. `setup.sh` and hook shims may remain as
  minimal launchers for portability.
- Publishing npm, PyPI, Homebrew, or Docker packages.
- Changing public Codex or Claude hook protocols.

## 5. Design

### 5.1 Production Path Definition

For this spec, "production path" means code that runs during:

- `bash setup.sh --yes`
- `bash setup.sh --check`
- `bash setup.sh --clean`
- installed Claude Code hook execution
- installed Codex hook execution
- `vibeguard-runtime codex-app-server-wrapper`

Python is allowed outside that path only for tests, development, eval, CI,
documentation generation, or optional language-specific guard tools.

### 5.2 Runtime Modules and Commands

Add Rust modules under `vibeguard-runtime/src/` for the remaining production
responsibilities:

- `runtime_config`: read user runtime config, project policy config, and
  schema-specific project policy validation.
- `runtime_policy`: own runtime policy decisions, including disabled hooks,
  enforcement mode, invalid-config handling, downgrade output, policy
  diagnostics, and visible error output.
- `install_state`: initialize, record, list, and drift-check
  `~/.vibeguard/install-state.json`.
- `setup_manifest`: enumerate install-module manifest links and rule labels now
  served by `scripts/lib/vibeguard_manifest.py`.
- `setup_home`: update Claude and Codex high-context files through structured,
  idempotent operations.
- `hook_pipeline`: optional follow-up command that runs normalization, policy,
  hook check, adaptation, status, and logging in one runtime process.

Expose them through stable CLI subcommands before deleting Python callers:

```text
vibeguard-runtime policy-check <hook-name>
vibeguard-runtime policy-downgrade-output
vibeguard-runtime policy-visible-failure <event-name>
vibeguard-runtime policy-diag <hook> <event> <kind>
vibeguard-runtime config-get <scope> <key> [default]
vibeguard-runtime install-state <init|record-file|record-tree|check|list>
vibeguard-runtime setup <install|check|clean>
vibeguard-runtime active-constraints ...
vibeguard-runtime hook-run <hook-name>
```

Command names can change during implementation, but each replacement must have a
test before the Python call site is removed.

### 5.3 Dependency Policy

The runtime intentionally keeps a small dependency surface. The setup migration
added `toml_edit` for structured `~/.codex/config.toml` mutation and kept
checksums local to the runtime instead of shelling out through Python. Future
setup dependencies must stay specific and justified:

- A checksum crate may be added only if the local implementation becomes a
  maintenance risk.
- Do not add a general JSON Schema engine unless the project schema cannot be
  represented as a small VibeGuard-specific validator.

Any new dependency must be covered by `cargo test`, release build CI, and the
existing release asset checksum flow.

### 5.4 Migration Order

1. Add Rust parity for policy/config and keep shell wrappers calling Rust.
2. Remove Python fallback from Codex normalization and adapter helpers.
3. Complete Rust parity for remaining configured hook Python snippets.
4. Add Rust setup/check/clean implementation behind the existing `setup.sh`
   bootstrap.
5. Update `setup.sh` to download/verify runtime first, then delegate production
   install/check/clean to Rust.
6. Add no-Python install and hook-path CI sentinels.
7. Optionally collapse multiple hook checks into `hook-run` for lower process
   count after parity is proven.

### 5.5 Fail-closed Rules

- A missing runtime is a visible install/hook failure.
- An unknown required runtime subcommand is a visible install/hook failure.
- Invalid `.vibeguard.json` is a visible policy/config error.
- A checksum mismatch aborts install.
- Removing a Python fallback requires a targeted regression test that proves the
  Rust behavior.

### 5.6 Compatibility

Existing shell commands remain valid:

```bash
bash setup.sh --yes
bash setup.sh --check
bash setup.sh --clean
```

The shell scripts become bootstraps, not alternate business-logic
implementations. They may use POSIX/Bash, `git`, `curl` or `gh`, and checksum
tools before the runtime is available, but not Python on supported release
targets.

## 6. Acceptance Criteria

- AC1: In a test home with `python3` intentionally absent from `PATH`,
  `bash setup.sh --yes --profile core` installs successfully on a supported
  release target using the verified prebuilt runtime. Enforced by
  `tests/setup/install_flow_tests.sh`.
- AC2: In that same environment, `bash setup.sh --check --strict` exits 0.
  Enforced by `tests/setup/install_flow_tests.sh`.
- AC3: In that same environment, `bash setup.sh --clean` removes VibeGuard-owned
  artifacts without Python. Enforced by `tests/setup/install_flow_tests.sh`.
- AC4: Configured Claude Code and Codex hook paths in `minimal`, `core`, `full`,
  and `strict` profiles do not execute `python3` for first-party runtime logic.
  Enforced by `scripts/ci/self-application/check-hook-production-python-free.sh`.
- AC5: No configured hook has a Python fallback for a runtime-replaced module.
  Enforced by `scripts/ci/self-application/check-hook-production-python-free.sh`.
- AC6: Existing Codex wrapper and app-server behavior tests still pass. Enforced
  by `tests/test_codex_runtime.sh`.
- AC7: Invalid project policy config remains fail-visible in shell-wrapper and
  app-server paths. Enforced by setup and runtime config regression tests.
- AC8: Docs distinguish "Python-free production path" from "Python-free whole
  repository". Enforced by this section.

## 7. Verification

Required implementation checks:

```bash
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash tests/test_setup.sh
bash tests/test_setup_check.sh
bash tests/test_codex_runtime.sh
bash tests/test_hooks.sh
bash tests/test_manifest_contract.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
bash scripts/ci/self-application/check-hook-production-python-free.sh
```

## 8. Risks and Open Questions

- High-context writes: migrating `CLAUDE.md`, `AGENTS.md`, `settings.json`,
  `hooks.json`, and `config.toml` must preserve dry-run diff behavior and
  confirmation semantics.
- TOML mutation: string editing would be fragile; use a structured Rust TOML
  API or keep the operation out of scope.
- Python guard packs: if users expect Python project guards during git hooks,
  document that those optional language checks still require Python.
- Release size and portability: new Rust dependencies may affect static Linux
  builds and must pass release workflow tests.
- App-server policy: this spec overlaps with the app-server policy-gate spec;
  the Rust policy module should be shared, not duplicated.

## 9. Routing Handoff

```yaml
handoff:
  mode: fixflow
  artifacts:
    - docs/specs/rust-only-production-path.md
    - plan/2026-06-05_22-28-rust-only-production-path.md
    - plan/w20-rust-only-production-path-snapshot.md
  runtime_pinning_snapshot: plan/w20-rust-only-production-path-snapshot.md
  verification_owner: implementation owner
  stop_conditions:
    - A high-context file write cannot preserve dry-run diff and confirmation semantics.
    - Rust policy/config behavior would intentionally diverge from existing wrapper behavior.
    - A Python fallback is removed before equivalent Rust regression coverage exists.
    - Release target builds fail after adding runtime dependencies.
  lane_map:
    runtime_policy_config: implementation owner
    hook_path_consolidation: implementation owner
    installer_consolidation: implementation owner
    docs_and_ci_gates: implementation owner
```
