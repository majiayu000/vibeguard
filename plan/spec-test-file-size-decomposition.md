# Spec: Decompose oversized test and runtime support files

- Status: Draft
- Date: 2026-06-04
- Owner: @majiayu000
- Issue: https://github.com/majiayu000/vibeguard/issues/375
- Readiness: plan_first
- Severity: P3
- Suggested labels: `enhancement`, `P3`, `dx`, `review`
- Related: `tests/test_setup.sh`, `tests/test_codex_runtime.sh`, `vibeguard-runtime/tests/cli.rs`, `scripts/lib/guard_packs.py`, `vibeguard-runtime/src/codex_hooks.rs`, `vibeguard-runtime/src/hook_checks_common.rs`

## Problem

Several test and support files exceed or approach the repository's U-16 file-size
limit. The current monoliths make focused changes hard to review, hide unrelated
test failures in large scripts, and increase the chance that future fixes become
opportunistic rewrites.

This is not an immediate correctness bug, but it is a maintainability issue that
will make future guard/runtime work riskier.

## Verified facts

Line counts from the audit:

| File | Lines |
| --- | ---: |
| `tests/test_setup.sh` | 1504 |
| `tests/test_codex_runtime.sh` | 1187 |
| `vibeguard-runtime/tests/cli.rs` | 1090 |
| `scripts/lib/guard_packs.py` | 793 |
| `vibeguard-runtime/src/codex_hooks.rs` | 735 |
| `vibeguard-runtime/src/hook_checks_common.rs` | 709 |

U-16 guidance says 200-400 lines is typical and 800 lines is the hard ceiling.

## Goals

- G1: Split files above 800 lines into domain-focused files.
- G2: Preserve existing aggregate commands so CI and users do not need to learn a
  new test entry point.
- G3: Keep behavior unchanged; this is a structural refactor.
- G4: Make future app-server, setup, and CLI changes easier to test in isolation.

## Non-goals

- Do not rewrite tests to a new framework.
- Do not change hook/runtime behavior as part of the split.
- Do not remove existing aggregate commands.
- Do not chase files below the ceiling unless the split is directly adjacent and
  low-risk.

## Design

### 1. Split `tests/test_codex_runtime.sh`

Keep `tests/test_codex_runtime.sh` as the aggregate runner. Move domain tests into
smaller files, for example:

- protocol helper tests.
- native wrapper tests.
- app-server tests.
- file-change tests.

Shared helpers should live in one helper file, not be duplicated.

### 2. Split `tests/test_setup.sh`

Keep `tests/test_setup.sh` as the aggregate runner. Move setup tests into domain
files, for example:

- install-state tests.
- config-validation tests.
- settings-write tests.
- health-check tests.

Preserve current setup test isolation behavior and cleanup traps.

### 3. Split Rust CLI integration tests

Split `vibeguard-runtime/tests/cli.rs` into multiple integration test files under
`vibeguard-runtime/tests/`, for example:

- `cli_json.rs`
- `cli_hook_checks.rs`
- `cli_policy.rs`
- `cli_session_metrics.rs`
- `cli_codex.rs`

Move shared Rust test helpers into a small module if needed.

### 4. Defer near-ceiling runtime support files unless needed

`scripts/lib/guard_packs.py`, `vibeguard-runtime/src/codex_hooks.rs`, and
`vibeguard-runtime/src/hook_checks_common.rs` are near the hard ceiling. Split
them only when the work can be done with mechanical, behavior-preserving module
extraction and full tests.

## Acceptance criteria

- AC1: No tracked source or test file remains above 800 lines, excluding generated
  or vendored files.
- AC2: `bash tests/test_setup.sh` still runs the full setup suite.
- AC3: `bash tests/test_codex_runtime.sh` still runs the full Codex runtime suite.
- AC4: `cargo test --manifest-path vibeguard-runtime/Cargo.toml` still runs the
  full Rust runtime suite.
- AC5: CI references do not break after the split.
- AC6: File movement is behavior-preserving; no assertions are weakened to make
  the split pass.

## Verification

Run these commands before closing the issue:

```bash
bash tests/test_setup.sh
bash tests/test_codex_runtime.sh
cargo test --manifest-path vibeguard-runtime/Cargo.toml
git ls-files -z | xargs -0 wc -l | sort -nr | head -20
```

If the implementation touches documentation paths or CI command references, also
run:

```bash
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```

## Routing handoff

```yaml
handoff:
  mode: plan_first
  artifacts:
    - plan/spec-test-file-size-decomposition.md
  runtime_pinning_snapshot: capture W-20 if this is implemented across more than one session.
  verification_owner: implementation owner
  stop_conditions:
    - Any split requires weakening or deleting existing assertions.
    - Aggregate test runners cannot be preserved.
  lane_map:
    shell_setup_tests: implementation owner
    shell_codex_tests: implementation owner
    rust_cli_tests: implementation owner
    optional_runtime_support_split: implementation owner
```
