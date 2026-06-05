# Rust-only production path execution plan

- Planned version: v1
- Applicable repository: `/Users/lifcc/Desktop/code/AI/tools/vibeguard`
- Execution mode: Change each step -> Test now -> Update plan -> Next step
- Routing readiness: `plan_first`
- Primary spec: `docs/specs/rust-only-production-path.md`
- GitHub umbrella: https://github.com/majiayu000/vibeguard/issues/371
- GitHub child issues: #381, #382, #383, #384, #385

## 0. Execution Constraints

- Objective: make the installed production path Python-free while preserving
  current hook behavior and fail-closed guarantees.
- Compatibility: required for existing `setup.sh`, Claude Code hooks, Codex
  hooks, and release binary install flow.
- Submission strategy: milestone. Do not combine hook runtime migration and
  installer migration into one large PR.
- Non-goals: eval, docs generation, CI-only scripts, optional language guard
  packs, package-manager publishing.
- Test strategy:
  - Step level: at least one directed regression test plus one health check per
    step.
  - Final: setup, Codex runtime, hook, Rust runtime, manifest, and doc validators.
- Constraints:
  - Search before adding files, functions, commands, tests, or rules.
  - Do not remove a Python fallback until Rust parity is covered by tests.
  - High-context file writes must keep dry-run diff and explicit confirmation.
  - No silent degradation: missing runtime, invalid config, or unknown subcommand
    must be visible.

## 1. Analysis Results

### Architecture Inventory Summary

- Runtime command entry: `vibeguard-runtime/src/main.rs`
- Runtime hook checks: `vibeguard-runtime/src/hook_checks*.rs`
- Codex runtime protocol helpers: `vibeguard-runtime/src/codex_hooks.rs`
- App-server guard proxy: `vibeguard-runtime/src/codex_app_server*.rs`
- Shell hook wrappers: `hooks/run-hook.sh`, `hooks/run-hook-codex.sh`,
  `hooks/_lib/*.sh`
- Runtime policy shell/Python layer: `hooks/_lib/policy.sh`,
  `hooks/_lib/policy.py`
- Setup shell layer: `setup.sh`, `scripts/setup/*.sh`,
  `scripts/setup/targets/*.sh`
- Setup Python helpers: `scripts/lib/settings_json.py`,
  `scripts/lib/codex_hooks_json.py`, `scripts/lib/codex_config_toml.py`,
  `scripts/lib/vibeguard_manifest.py`, `scripts/lib/claude_md.py`,
  `scripts/lib/project_config_validate.py`
- Install-state shell/Python layer: `scripts/lib/install-state.sh`,
  `scripts/lib/file_ops.py`

### Redundant or Parallel Implementation Findings

| id | category | files and symbols | evidence | impact | risk | convergence direction |
|----|----------|-------------------|----------|--------|------|-----------------------|
| F1 | runtime policy split | `hooks/_lib/policy.sh`, `hooks/_lib/policy.py`, app-server policy specs | Shell wrappers enforce policy through Python; app-server needs Rust-side policy parity. | high | high | Create one Rust `runtime_policy` module and have shell/app-server paths call it. |
| F2 | apply_patch normalizer fallback | `hooks/_lib/codex_runner.sh`, `hooks/_lib/codex_apply_patch_adapter.py`, `vibeguard-runtime/src/codex_hooks.rs` | Runner already calls `codex-normalize-apply-patch`, then falls back to Python. | medium | medium | Delete fallback after runtime parity tests cover Add/Update/Delete/Move patch payloads. |
| F3 | pre-edit duplicate path | `hooks/pre-edit-guard.sh`, `vibeguard-runtime/src/hook_checks.rs` | Shell hook calls Rust fast path, then keeps inline Python full implementation. | high | high | Extend Rust `pre-edit-check` until it owns the full behavior, then remove inline Python. |
| F4 | setup config helpers in Python | `scripts/setup/lib.sh`, `scripts/setup/targets/*.sh`, `scripts/lib/*.py` | Setup writes JSON/TOML/Markdown high-context files via Python helpers. | high | high | Add Rust setup/check/clean commands with structured JSON/TOML/Markdown handling. |
| F5 | install state in Python | `scripts/lib/install-state.sh`, `scripts/lib/file_ops.py` | Install-state init/record/check/list use inline Python and checksums. | medium | medium | Move install-state operations into Rust before setup can be no-Python. |
| F6 | configured hook snippets still spawn Python | `hooks/count_active_constraints.sh`, `hooks/post-build-check.sh`, `hooks/learn-evaluator.sh`, `hooks/_lib/config.sh`, `hooks/_lib/log_redact.sh` | Full/strict profiles can still reach Python snippets outside pre-edit and policy. | medium | medium | Inventory configured profile hooks and migrate only first-party production snippets. |
| F7 | low-value Python remains outside production path | `eval/*.py`, `scripts/precision-tracker.py`, CI-only validators | These do not run during install or normal hooks. | low | low | Keep out of scope; document as dev/eval tooling. |

## 2. Detailed Steps

### Step P0 Baseline and W-20 Snapshot

- status: `completed`
- Target: capture the execution baseline and freeze the scope before code edits.
- Expected changes to files:
  - `plan/w20-rust-only-production-path-snapshot.md`
  - `docs/specs/rust-only-production-path.md`
  - `plan/2026-06-05_22-28-rust-only-production-path.md`
- Detailed changes:
  - Record branch, commit, dirty state, tool versions, release assets, current
    runtime version, and installed snapshot.
  - Define production-path boundaries and explicit non-goals.
  - Record the migration findings and step order.
- step-level test command:
  - `git status --short --branch`
  - `bash workflows/plan-flow/scripts/redundancy_scan.sh vibeguard-runtime/src`
  - `rg -n "python3|codex-normalize-apply-patch|policy.py|settings_json.py|codex_hooks_json.py|codex_config_toml.py|vibeguard_manifest.py|claude_md.py|project_config_validate.py" hooks scripts/setup scripts/lib vibeguard-runtime/src -g '!target'`
- Completion judgment:
  - Spec, plan, and W-20 snapshot exist.
  - No implementation files are changed in this step.

### Step P1 Runtime Policy and Config Canonicalization

- status: `in_progress`
- Issue: https://github.com/majiayu000/vibeguard/issues/381
- Target: replace `hooks/_lib/policy.py` and project/user config Python reads
  with Rust runtime commands.
- Expected changes to files:
  - `vibeguard-runtime/src/main.rs`
  - `vibeguard-runtime/src/` planned module: runtime_config
  - `vibeguard-runtime/src/` planned module: runtime_policy
  - `vibeguard-runtime/tests/cli.rs`
  - `hooks/_lib/policy.sh`
  - `hooks/_lib/config.sh`
  - `scripts/lib/project_config.sh`
- Detailed changes:
  - Add Rust project policy config validation for the fields used by hooks:
    `disabled_hooks`, profile/enforcement, and related runtime policy keys.
  - Add Rust user runtime config reads for thresholds and write mode.
  - Add commands for policy check, downgrade output, visible failure output, and
    policy diagnostics.
  - Update shell wrappers to call the runtime command and fail visibly if it is
    unavailable.
- step-level test command:
  - `cargo test --manifest-path vibeguard-runtime/Cargo.toml runtime_policy`
  - `bash tests/hooks/test_runtime_policy.sh`
  - `bash tests/test_codex_runtime.sh`
- Completion judgment:
  - Shell and app-server policy behavior share Rust logic.
  - Invalid policy config remains visible.
  - No `hooks/_lib/policy.py` production caller remains.

### Step P2 Codex Normalizer and Adapter Fallback Removal

- status: `pending`
- Issue: https://github.com/majiayu000/vibeguard/issues/382
- Target: make Codex wrapper normalization/adaptation Rust-only for configured
  native hooks.
- Expected changes to files:
  - `hooks/_lib/codex_runner.sh`
  - `hooks/_lib/codex_adapter.sh`
  - `hooks/_lib/codex_diag.sh`
  - `hooks/run-hook-codex.sh`
  - `vibeguard-runtime/src/codex_hooks.rs`
  - `vibeguard-runtime/tests/cli.rs`
  - `tests/test_codex_runtime.sh`
- Detailed changes:
  - Remove `hooks/_lib/codex_apply_patch_adapter.py` from production fallback
    after equivalent Rust coverage exists.
  - Move remaining Codex visible-failure and status payload builders to runtime
    commands.
  - Keep shell wrapper as a dispatcher only.
- step-level test command:
  - `cargo test --manifest-path vibeguard-runtime/Cargo.toml codex`
  - `bash tests/test_codex_runtime.sh`
  - `bash scripts/ci/self-application/check-codex-wrapper-thin.sh`
- Completion judgment:
  - Apply-patch Add/Update/Delete/Move payloads normalize through Rust only.
  - Wrapped hook output adaptation is fail-closed and Python-free.

### Step P3 Remaining Configured Hook Python Snippets

- status: `pending`
- Issue: https://github.com/majiayu000/vibeguard/issues/383
- Target: remove Python from first-party configured hook execution in
  minimal/core/full/strict profiles.
- Expected changes to files:
  - `hooks/pre-edit-guard.sh`
  - `hooks/pre-write-guard.sh`
  - `hooks/post-build-check.sh`
  - `hooks/count_active_constraints.sh`
  - `hooks/learn-evaluator.sh`
  - `hooks/_lib/post_edit_quality.sh`
  - `hooks/_lib/post_edit_history.sh`
  - `hooks/_lib/log_redact.sh`
  - `hooks/_lib/log_timer.sh`
  - `vibeguard-runtime/src/hook_checks.rs`
  - `vibeguard-runtime/src/log_query.rs`
  - `vibeguard-runtime/src/session_metrics/`
  - `tests/test_hooks.sh`
- Detailed changes:
  - Extend existing Rust pre-edit/pre-write/post-write/log-query commands until
    they cover the remaining inline Python branches.
  - Add runtime output helpers for JSON payloads currently built with Python.
  - Treat optional language guard scripts as out of scope unless they are run by
    configured production hooks without a user-selected language pack.
- step-level test command:
  - `cargo test --manifest-path vibeguard-runtime/Cargo.toml hook_checks`
  - `bash tests/test_hooks.sh`
  - `bash tests/test_hook_status.sh`
- Completion judgment:
  - Configured first-party hooks do not spawn Python for runtime logic.
  - Existing hook behavior tests still pass.

### Step P4 Rust Setup, Check, Clean Core

- status: `pending`
- Issue: https://github.com/majiayu000/vibeguard/issues/384
- Target: move setup/check/clean business logic from Python helpers into
  `vibeguard-runtime`.
- Expected changes to files:
  - `vibeguard-runtime/src/main.rs`
  - `vibeguard-runtime/src/` planned module: setup
  - `vibeguard-runtime/src/` planned module: setup_manifest
  - `vibeguard-runtime/src/` planned module: setup_home
  - `vibeguard-runtime/src/` planned module: install_state
  - `scripts/setup/lib.sh`
  - `scripts/setup/install.sh`
  - `scripts/setup/check.sh`
  - `scripts/setup/clean.sh`
  - `scripts/setup/targets/claude-home.sh`
  - `scripts/setup/targets/codex-home.sh`
  - `tests/test_setup.sh`
  - `tests/test_setup_check.sh`
- Detailed changes:
  - Add Rust install-state init/record/tree/check/list.
  - Add Rust manifest enumeration for skills and rules.
  - Add Rust idempotent updates for Claude settings, Codex hooks JSON, Codex
    config TOML, and AGENTS/CLAUDE rule blocks.
  - Preserve dry-run diff and high-context confirmation semantics.
- step-level test command:
  - `cargo test --manifest-path vibeguard-runtime/Cargo.toml setup`
  - `bash tests/test_setup.sh`
  - `bash tests/test_setup_check.sh`
  - `bash scripts/ci/validate-manifest-contract.sh`
- Completion judgment:
  - Setup/check/clean business logic has Rust coverage.
  - Shell setup scripts no longer call Python helpers for production install.

### Step P5 No-Python Install Gate and Documentation

- status: `pending`
- Issue: https://github.com/majiayu000/vibeguard/issues/385
- Target: prove and document the Python-free production path.
- Expected changes to files:
  - `tests/test_setup.sh` or a focused new no-Python setup test
  - `scripts/ci/self-application/check-u29-no-silent-degrade.sh`
  - `README.md`
  - `docs/README_CN.md`
  - `docs/specs/rust-only-production-path.md`
  - `.github/workflows/ci.yml`
- Detailed changes:
  - Add a test that removes `python3` from `PATH` while preserving required
    bootstrap tools and verifies setup/check/clean on a supported release target.
  - Add a CI sentinel that fails if configured production hook paths regain
    Python fallback references for runtime-replaced modules.
  - Update docs to state that production install/runtime is Python-free, while
    eval/dev tools and optional Python guard packs may still require Python.
- step-level test command:
  - `bash tests/test_setup.sh`
  - `bash scripts/ci/self-application/run-all.sh`
  - `bash scripts/ci/validate-doc-paths.sh`
  - `bash scripts/ci/validate-doc-command-paths.sh`
- Completion judgment:
  - No-Python install/check/clean is enforced by tests.
  - Public docs match the actual dependency boundary.

### Step P6 Optional Hook Pipeline Consolidation

- status: `pending`
- Target: reduce hook process count after Rust parity is stable.
- Expected changes to files:
  - `vibeguard-runtime/src/` planned module: hook_pipeline
  - `vibeguard-runtime/src/main.rs`
  - `hooks/run-hook.sh`
  - `hooks/run-hook-codex.sh`
  - `tests/bench_hook_latency.sh`
  - `tests/test_hook_perf_contract.sh`
- Detailed changes:
  - Add `vibeguard-runtime hook-run <hook-name>` to combine policy, config,
    normalization, check, output adaptation, status, and logging in one runtime
    process where possible.
  - Keep legacy shell entry points as compatibility wrappers.
  - Compare latency before and after to ensure the extra abstraction pays for
    itself.
- step-level test command:
  - `bash tests/bench_hook_latency.sh`
  - `bash tests/test_hook_perf_contract.sh`
  - `bash tests/test_codex_runtime.sh`
- Completion judgment:
  - Hook latency improves or remains neutral.
  - No behavior regression in configured hooks.

## 3. Regression Test Matrix

- Rust runtime:
  - `cargo check --manifest-path vibeguard-runtime/Cargo.toml`
  - `cargo test --manifest-path vibeguard-runtime/Cargo.toml`
- Setup:
  - `bash tests/test_setup.sh`
  - `bash tests/test_setup_check.sh`
- Hooks:
  - `bash tests/test_hooks.sh`
  - `bash tests/test_codex_runtime.sh`
  - `bash tests/test_hook_status.sh`
  - `bash tests/test_hook_perf_contract.sh`
- Contracts and docs:
  - `bash scripts/ci/validate-manifest-contract.sh`
  - `bash scripts/ci/validate-doc-paths.sh`
  - `bash scripts/ci/validate-doc-command-paths.sh`
  - `python3 workflows/plan-flow/scripts/plan_lint.py plan/2026-06-05_22-28-rust-only-production-path.md`

## 4. Execution Log

- 2026-06-05
  - Step P0: `completed`
    - Modified files:
      - `docs/specs/rust-only-production-path.md`
      - `plan/2026-06-05_22-28-rust-only-production-path.md`
      - `plan/w20-rust-only-production-path-snapshot.md`
    - Main changes:
      - Captured baseline facts, production-path scope, non-goals, findings,
        and phased execution plan.
    - Execute tests:
      - `git status --short --branch` -> pass; showed `main...origin/main`
        and a pre-existing unrelated untracked docs spec file.
      - `bash workflows/plan-flow/scripts/redundancy_scan.sh vibeguard-runtime/src` -> pass; no duplicate exported type names found.
      - `rg -n "python3|codex-normalize-apply-patch|policy.py|settings_json.py|codex_hooks_json.py|codex_config_toml.py|vibeguard_manifest.py|claude_md.py|project_config_validate.py" hooks scripts/setup scripts/lib vibeguard-runtime/src -g '!target'` -> pass; identified production Python surfaces for this plan.
    - GitHub issue tracking:
      - `#381`, `#382`, `#383`, `#384`, and `#385` opened under umbrella `#371`.

## 5. Routing Handoff

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
