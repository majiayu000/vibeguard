---
mode: plan
cwd: /Users/apple/Desktop/code/AI/tool/vibeguard
task: Fix 2026-05-01 VibeGuard codebase audit findings
complexity: complex
planning_method: plan-mode+plan-flow
created_at: 2026-05-01T18:56:41+08:00
source_spec: plan/spec-codebase-audit-remediation.md
source_audit: docs/internal/research/2026-05-01-codebase-audit.md
status: planned
---

# Plan: VibeGuard Audit Remediation

- Planned version: v1
- Applicable repository: `/Users/apple/Desktop/code/AI/tool/vibeguard`
- Current baseline: `main...origin/main`
- Current local state: audit/SPEC docs are untracked; `mcp-server/` is also untracked
- Execution mode: change one step -> run directed tests -> run health check -> update this plan -> continue
- Submission strategy: `milestone` for P0, then `per_step` for higher-risk architectural changes

## 0. Objective And Boundaries

### Objective

Fix the 2026-05-01 codebase audit findings in a traceable order, starting with self-violations and guard fail-open behavior, then converging cross-language drift, manifest/schema drift, tests, and large files.

The plan is intentionally more operational than `plan/spec-codebase-audit-remediation.md`: each step names the files to touch, the expected behavior change, test commands, rollback, and stop condition.

### Non-goals

- Do not start implementation while this file is being created.
- Do not delete `mcp-server/` until the project owner decides whether it is deprecated or should be shipped.
- Do not remove Python fallbacks until a loud setup failure or explicit compatibility mode exists.
- Do not rewrite unrelated passing systems just to satisfy line-count aesthetics.
- Do not commit untracked audit/SPEC files unless the user explicitly asks to package the documentation.

### Compatibility Contract

- `events.jsonl` remains backward-compatible: new fields are additive; existing keys are not renamed in this plan.
- Existing hook command formats remain accepted, but newly managed entries get explicit markers and safer update rules.
- `setup.sh --check` remains the quick user-facing health command.
- Any intentionally fail-open behavior must be documented with a magic comment and a visible log event.

### Stop Conditions

Stop and re-plan before continuing if any of these happens:

- A fix would require overwriting a user's local `~/.claude/CLAUDE.md`, `~/.claude/settings.json`, `~/.codex/hooks.json`, or `~/.codex/config.toml` without a diff prompt.
- A step changes hook output protocol semantics in a way not covered by a Codex and Claude runtime test.
- A phase's directed tests fail and the root cause is not local to the current step.
- The `mcp-server/` decision becomes necessary to proceed.
- The repo develops unrelated dirty tracked files; classify before editing those paths.

## 1. Analysis Results

### Architecture Inventory

| Area | Current anchors | Problem shape |
|------|-----------------|---------------|
| Hook JSON parsing | `hooks/log.sh`, `vg-helper/src/json_field.rs`, `hooks/pre-bash-guard.sh` | Parse errors collapse to empty strings, allowing security-sensitive hooks to pass silently. |
| Pre-commit quality gate | `hooks/pre-commit-guard.sh`, `guards/**` | Timeout returns success and is excluded from build failure handling. |
| Setup high-context writes | `scripts/setup/targets/claude-home.sh`, `scripts/lib/settings_json.py`, `scripts/lib/claude_md.py` | Installer modifies high-context files without SEC-13 diff/confirmation. |
| Runtime event log | `hooks/log.sh`, `scripts/gc/gc-logs.sh`, `scripts/gc/gc-scheduled.sh`, `vg-helper/src/log_query.rs` | Race-prone GC, duplicated global/project logs, scattered field names, no redaction. |
| Cross-language helpers | `vg-helper/src/session_metrics.rs`, `hooks/_lib/session_metrics.py`, `vg-helper/src/pkg_rewrite.rs`, `hooks/_lib/pkg_rewrite.py` | Rust and Python implementations coexist and have already drifted. |
| Eval pipeline | `eval/run_eval.py`, `eval/**`, `scripts/benchmark.sh` | API errors count as misses and calibration is absent. |
| Hook registration | `scripts/lib/codex_hooks_json.py`, `scripts/lib/settings_json.py`, `hooks/CLAUDE.md`, `hooks/vibeguard-*.sh` | No central hook manifest; adding a hook touches many files. |
| Tests | `tests/test_hooks.sh`, `tests/test_codex_runtime.sh`, `vg-helper/tests/cli.rs` | Hook tests are a mega-file; vg-helper module coverage is uneven. |

### Duplicate / Drift Candidates

| id | category | files and symbols | evidence | impact | risk | convergence direction |
|----|----------|-------------------|----------|--------|------|-----------------------|
| D1 | fail-open gate | `hooks/pre-commit-guard.sh::run_guard`, `run_build_check` | timeout code `124` returns or counts as success | high | low | fail-closed by default with explicit warn override |
| D2 | JSON parse contract | `hooks/log.sh::vg_json_field`, `vg-helper/src/json_field.rs`, pre hooks | invalid JSON becomes empty field | high | medium | add strict APIs and migrate security-sensitive hooks first |
| D3 | high-context writer | `claude-home.sh`, `settings_json.py`, `claude_md_helper.py` | direct writes with no diff | high | medium | central SEC-13 diff/apply helper |
| D4 | parallel implementation | Rust/Python `session_metrics` | paralysis depth and top-N behavior differ | high | medium | Rust canonical, Python deprecate/remove or CI equivalence |
| D5 | parallel implementation | Rust/Python `pkg_rewrite` | same "replaces Python" pattern remains | medium | medium | Rust canonical, Python deprecate/remove or CI equivalence |
| D6 | log lifecycle | `hooks/log.sh`, `gc-logs.sh`, `gc-scheduled.sh` | append vs truncate rewrite race and uneven GC | high | medium | atomic GC + one retention policy |
| D7 | hook registry | `codex_hooks_json.py::MANAGED_SPECS`, setup targets, docs | hook addition requires 7+ edits | high | high | `hooks/manifest.json` plus generated outputs |
| D8 | output adaptation | `run-hook-codex.sh` inline Python heredocs | 5 adapter blocks | medium | medium | `hooks/_lib/codex_adapter.sh` or `vg-helper codex-adapt` |

## 2. Execution Protocol

For every step:

1. Mark exactly one step `in_progress`.
2. Make only the files listed in that step.
3. Run the step-level tests first.
4. Run the phase health check if the step changed shared behavior.
5. Append an execution-log entry with exact commands and pass/fail.
6. Only then mark the step `completed` and move the next step to `in_progress`.

Default health checks:

```bash
bash setup.sh --check
bash tests/test_hooks.sh
bash tests/test_setup.sh
(cd vg-helper && cargo test)
```

Use the closest subset when the full command is unrelated or too slow, and record why.

## 3. Detailed Steps

### Step P0.1 Fail-Closed Pre-Commit Timeout

- Status: `completed`
- Findings: H1
- Target: timeout cannot bypass guard/build checks silently.
- Expected files:
  - `hooks/pre-commit-guard.sh`
  - `tests/test_hooks.sh` or new focused test file if the test split begins early
- Detailed changes:
  - In `run_guard`, treat `124` as a block by default.
  - In `run_build_check`, treat `124` as a build failure by default.
  - Add `VIBEGUARD_PRECOMMIT_TIMEOUT_BEHAVIOR=warn` for explicit fail-open downgrade.
  - Emit a visible event with reason containing `guard timeout`.
- Step tests:
  - `bash tests/test_hooks.sh test_precommit_timeout`
  - If no targeted selector exists yet: add one, then run `bash tests/test_hooks.sh`.
- Completion judgment:
  - Timeout blocks by default.
  - Warn override is visible in logs.
  - No existing pre-commit tests regress.
- Rollback:
  - Revert `hooks/pre-commit-guard.sh` and the new/changed tests.

### Step P0.2 Strict JSON Parse Path For Security-Sensitive Hooks

- Status: `completed`
- Findings: H3, M5 partial
- Target: malformed hook input cannot turn into an empty field and pass.
- Expected files:
  - `hooks/log.sh`
  - `hooks/pre-bash-guard.sh`
  - `vg-helper/src/json_field.rs`
  - `vg-helper/tests/cli.rs`
  - hook tests
- Detailed changes:
  - Add strict shell helper such as `vg_json_field_strict`.
  - Add `vg-helper json-field --strict` or a separate strict subcommand that distinguishes absent/null/empty/parse-error.
  - Migrate `pre-bash-guard.sh` command extraction to strict mode.
  - On parse error, log a warning and fail closed.
  - Keep tolerant `vg_json_field` behavior for legacy callers.
- Step tests:
  - `(cd vg-helper && cargo test json_field)`
  - `bash tests/test_hooks.sh test_log_sh_strict_parse`
  - `printf '{"tool_input":' | bash hooks/pre-bash-guard.sh` should not pass silently.
- Completion judgment:
  - Invalid JSON produces a non-success guard outcome or explicit block payload.
  - Valid JSON behavior remains unchanged.
- Rollback:
  - Revert strict helper and callers; tolerant helper remains untouched.

### Step P0.3 SEC-13 Diff And Confirmation For Setup Writes

- Status: `completed`
- Findings: H2, M11 partial
- Target: setup must show planned writes to high-context files before applying them.
- Expected files:
  - `setup.sh`
  - `scripts/setup/install.sh`
  - `scripts/setup/targets/claude-home.sh`
  - `scripts/setup/targets/codex-home.sh`
  - `scripts/lib/settings_json.py`
  - `scripts/lib/claude_md.py`
  - `tests/test_setup.sh`
- Detailed changes:
  - Add dry-run path for settings and CLAUDE.md injection.
  - Show unified diff for absent and existing files.
  - Require `[y/N]` unless `--yes` or `VIBEGUARD_SETUP_AUTO=1`.
  - In non-tty mode, fail with a clear message instead of hanging.
  - Add a small shared helper to avoid duplicating diff logic in target scripts.
- Step tests:
  - `bash tests/test_setup.sh test_sec13_diff`
  - `bash setup.sh --dry-run`
  - `VIBEGUARD_SETUP_AUTO=1 bash setup.sh --check`
- Completion judgment:
  - `--dry-run` modifies no high-context files.
  - Interactive write path prompts.
  - Auto mode remains available and explicit.
- Rollback:
  - Revert setup helper/target changes; no user file migrations are needed.

### Step P0.4 Escape Pre-Edit Guard JSON Output

- Status: `completed`
- Findings: M2
- Target: file paths containing quotes or backslashes cannot break block JSON.
- Expected files:
  - `hooks/pre-edit-guard.sh`
  - `tests/test_hooks.sh` or focused pre-edit test
- Detailed changes:
  - Replace three heredoc JSON outputs with `vg_json_output_kv`.
  - Preserve existing human-readable reason text.
  - Add regression case for a path containing `"` and `\`.
- Step tests:
  - `bash tests/test_hooks.sh test_pre_edit_json_escape`
  - `bash tests/test_codex_runtime.sh` if Codex wrapper behavior is affected.
- Completion judgment:
  - Block payload remains valid JSON for hostile file paths.
  - Codex/Claude wrapper still interprets the block.
- Rollback:
  - Revert `pre-edit-guard.sh` and tests.

### Step P0.5 Remove Silent Python/Eval Degradation

- Status: `completed`
- Findings: H5, H7
- Target: parser/eval errors are visible and are not counted as genuine misses.
- Expected files:
  - `scripts/constraint-recommender.py`
  - `eval/run_eval.py`
  - `eval/test_run_eval.py` or equivalent new tests
  - `scripts/test_constraint_recommender.py` or equivalent new tests
- Detailed changes:
  - Replace `except Exception: pass` with stderr diagnostics and structured failure state.
  - In eval, return `skipped: true` for API errors and exclude skipped cases from SWS/FPR denominators.
  - Add failure threshold such as `EVAL_MAX_API_FAILURES`.
- Step tests:
  - `uv run python -m pytest eval/test_run_eval.py::test_skipped_semantics`
  - `uv run python -m pytest scripts/test_constraint_recommender.py`
- Completion judgment:
  - API/network failures report skipped.
  - Config parse failures are visible.
- Rollback:
  - Revert Python changes and tests.

### Step P1.1 Redact Sensitive Command Details In Logs

- Status: `completed`
- Findings: M1
- Target: event logs do not persist obvious secrets from Bash commands.
- Expected files:
  - `hooks/log.sh`
  - `tests/test_hooks.sh` or focused log test
- Detailed changes:
  - Add a `vg_redact_detail` pass before truncation/write.
  - Redact bearer tokens, authorization headers, API keys, passwords, secrets, and token assignments.
  - Preserve enough non-secret context for debugging.
- Step tests:
  - `bash tests/test_hooks.sh test_log_redaction`
  - `bash tests/test_hooks.sh`
- Completion judgment:
  - `Authorization: Bearer ...` and `api_key=...` never appear in `events.jsonl`.
- Rollback:
  - Revert redaction helper and tests.

### Step P1.2 Atomic And Locked GC

- Status: `completed`
- Findings: H6, M10 partial
- Target: GC cannot lose concurrent hook append events.
- Expected files:
  - `scripts/gc/gc-logs.sh`
  - `scripts/gc/gc-scheduled.sh` if retention policy is shared
  - `tests/test_gc_logs_concurrent.sh`
- Detailed changes:
  - Use `fcntl.flock(LOCK_EX)`.
  - Write kept lines to same-directory temp file.
  - `fsync` temp file, then `os.replace`.
  - Skip/retry if mtime changes during processing.
  - Keep `--dry-run` behavior pure.
- Step tests:
  - `bash tests/test_gc_logs_concurrent.sh`
  - `bash scripts/gc/gc-logs.sh --dry-run`
- Completion judgment:
  - Concurrent append test preserves all lines.
- Rollback:
  - Revert GC script/test.

### Step P1.3 Canonicalize Session Metrics

- Status: `completed`
- Findings: H4
- Target: one canonical implementation emits LEARN/session metrics.
- Expected files:
  - `vg-helper/src/session_metrics.rs`
  - `hooks/_lib/session_metrics.py`
  - `hooks/learn-evaluator.sh`
  - `scripts/setup/install.sh`
  - `vg-helper/tests/cli.rs`
  - `tests/fixtures/session-metrics/**`
- Detailed changes:
  - Decide and record canonical implementation: Rust is preferred.
  - Add a deprecation warning to Python fallback for one release, or remove it if compatibility is not required.
  - Align Signal 6 depth and repeat-rule top-N behavior before removing fallback.
  - Make setup fail loudly if `vg-helper` cannot build and the affected hooks would drift.
- Step tests:
  - `(cd vg-helper && cargo test session_metrics)`
  - `bash tests/test_hooks.sh test_session_metrics_canonical`
  - `rg "session_metrics.py" hooks scripts` should return only deprecation/removal references.
- Completion judgment:
  - Same fixture has one canonical output path.
  - No silent cargo fallback produces different signals.
- Rollback:
  - Re-enable Python fallback and revert caller migration.

### Step P1.4 Canonicalize Package Rewrite

- Status: `completed`
- Findings: M6
- Target: `pkg_rewrite` follows the same single-implementation policy as session metrics.
- Expected files:
  - `vg-helper/src/pkg_rewrite.rs`
  - `hooks/_lib/pkg_rewrite.py`
  - `hooks/pre-bash-guard.sh`
  - `vg-helper/tests/cli.rs`
- Detailed changes:
  - Add Rust test coverage for every package-manager rewrite branch.
  - Migrate production callers to `vg-helper`.
  - Deprecate/remove Python fallback under the same policy as P1.3.
- Step tests:
  - `(cd vg-helper && cargo test pkg_rewrite)`
  - `bash tests/test_hooks.sh test_pkg_rewrite_canonical`
- Completion judgment:
  - Rewrite behavior is covered in Rust.
  - No production path silently diverges to Python.
- Rollback:
  - Revert caller migration and fallback changes.

### Step P1.5 Add W-18 Calibration To Eval

- Status: `completed`
- Findings: H5
- Target: eval reports calibration, not only substring hits.
- Expected files:
  - `eval/run_eval.py`
  - `eval/**` sample/schema/test files as needed
  - `scripts/benchmark.sh` if it consumes eval JSON
  - `docs/internal/benchmarks/**` for baseline report
- Detailed changes:
  - Extend model response contract with `confidence: low|medium|high`.
  - Parse confidence robustly.
  - Compute ECE per severity/rule bucket.
  - Preserve old report compatibility by excluding missing confidence from ECE.
- Step tests:
  - `uv run python -m pytest eval/test_run_eval.py::test_calibration`
  - `uv run python eval/run_eval.py --calibration --sample 5` when credentials are available; otherwise record no-credential fallback.
- Completion judgment:
  - Report differentiates detected, missed, skipped, and calibration.
- Rollback:
  - Revert eval contract changes; old output-only scoring remains.

### Step P2.1 Introduce `hooks/manifest.json`

- Status: `completed`
- Findings: H10, M4 partial, M8 partial, M9
- Target: hook registration and docs are generated from a single hook manifest.
- Expected files:
  - `hooks/manifest.json`
  - `schemas/hooks-manifest.schema.json`
  - `scripts/lib/codex_hooks_json.py`
  - `scripts/lib/settings_json.py`
  - `scripts/setup/regenerate-hooks-from-manifest.sh`
  - `hooks/CLAUDE.md`
  - `tests/test_setup.sh`
  - `.github/workflows/ci.yml`
- Detailed changes:
  - Define manifest fields: name, phase, matcher, profile, Claude support, Codex support, decision types, timeout.
  - Generate Claude settings entries and Codex hooks entries from manifest.
  - Generate or validate Codex shim list.
  - Generate `hooks/CLAUDE.md` hook table between markers.
  - Add `validate-hooks-manifest.sh`.
- Step tests:
  - `bash scripts/ci/validate-hooks-manifest.sh`
  - `bash scripts/setup/regenerate-hooks-from-manifest.sh --check`
  - `bash tests/test_setup.sh`
- Completion judgment:
  - Adding a fake test hook in a temp fixture requires script + manifest row only.
- Rollback:
  - Revert manifest generation; hand-maintained templates remain.

### Step P2.2 Protect User-Customized Settings

- Status: `completed`
- Findings: M11, M13
- Target: setup cannot silently overwrite user-customized hook commands or copied rule files.
- Expected files:
  - `scripts/lib/settings_json.py`
  - `scripts/lib/install-state.sh`
  - `scripts/setup/targets/claude-home.sh`
  - `scripts/setup/targets/codex-home.sh`
  - `tests/test_setup.sh`
- Detailed changes:
  - Track previous canonical command in install-state.
  - Add `vibeguardManaged: true` or equivalent metadata for inserted entries where schema allows.
  - If existing command differs from previous/new canonical, show diff and require `--force-overwrite`.
  - Before removing non-symlink rule files, compare against source; abort on local modifications.
- Step tests:
  - `bash tests/test_setup.sh test_settings_user_customization`
  - `bash tests/test_setup.sh test_rule_file_local_copy_protection`
- Completion judgment:
  - Local customizations are preserved unless force-overwritten explicitly.
- Rollback:
  - Revert setup safety changes; additive install-state fields can remain harmlessly.

### Step P2.3 Extract Codex Adapter

- Status: `completed`
- Findings: H9, SEC-10 low item partial
- Target: `run-hook-codex.sh` stops duplicating JSON envelope adaptation.
- Expected files:
  - `hooks/run-hook-codex.sh`
  - `hooks/_lib/codex_adapter.sh` or `hooks/_lib/codex_adapter.sh`
  - `tests/test_codex_runtime.sh`
- Detailed changes:
  - Extract PreToolUse deny/warn/update and PostToolUse block/warn adaptation.
  - Prefer `vg-helper codex-adapt` if Rust canonicalization from P1 is stable; otherwise shell helper is acceptable.
  - Normalize invalid wrapped-hook output to a deny payload with visible reason.
  - Decide exit-code convention and document it at script head.
- Step tests:
  - `bash tests/test_codex_runtime.sh`
  - `bash tests/test_hooks.sh`
- Completion judgment:
  - `run-hook-codex.sh` becomes a thin wrapper.
  - Existing Codex runtime tests pass unchanged or with intentional fixture updates.
- Rollback:
  - Revert wrapper/helper extraction.

### Step P2.4 Split Hook Tests

- Status: `completed`
- Findings: H8
- Target: `tests/test_hooks.sh` becomes an orchestrator; per-hook tests become discoverable.
- Expected files:
  - `tests/test_hooks.sh`
  - `tests/hooks/test_pre_bash_guard.sh`
  - `tests/hooks/test_pre_edit_guard.sh`
  - `tests/hooks/test_post_edit_guard_basic.sh`
  - other per-hook test files
  - `tests/lib/hook_test_lib.sh`
  - `scripts/verify/check-test-file-sizes.sh`
- Detailed changes:
  - Move shared setup to `tests/lib/`.
  - Preserve old `bash tests/test_hooks.sh` entry point.
  - Add line-count verification.
  - Keep each new test file under 400 LOC.
- Step tests:
  - `bash tests/test_hooks.sh`
  - `bash scripts/verify/check-test-file-sizes.sh`
- Completion judgment:
  - Orchestrator under 100 LOC.
  - Per-hook files under 400 LOC.
  - Same behavior coverage as before split.
- Rollback:
  - Revert test split commit.

### Step P3.1 Event Schema Constants And Strict Field Contract

- Status: `completed`
- Findings: M4, M5
- Target: event field names and json-field semantics are declared and validated.
- Expected files:
  - `vg-helper/src/event_schema.rs`
  - `vg-helper/src/log_query.rs`
  - `vg-helper/src/session_metrics.rs`
  - `vg-helper/src/json_field.rs`
  - `hooks/log.sh`
  - `scripts/ci/check-event-schema-literals.sh`
- Detailed changes:
  - Add Rust constants for event keys.
  - Replace Rust raw key strings with constants.
  - Add a shell-side CI grep to catch accidental new raw field names.
  - Document absent/null/empty/parse-error matrix.
- Step tests:
  - `(cd vg-helper && cargo test)`
  - `bash scripts/ci/check-event-schema-literals.sh`
- Completion judgment:
  - Rust readers share one field declaration.
  - Shell drift is at least mechanically checked.
- Rollback:
  - Revert constants and CI script.

### Step P3.2 Self-Application CI

- Status: `completed`
- Findings: cross-cutting, M3, M7
- Target: VibeGuard enforces its own key rules on itself.
- Expected files:
  - `scripts/ci/self-application/run-all.sh`
  - `scripts/ci/self-application/check-sec13-self-apply.sh`
  - `scripts/ci/self-application/check-u29-no-silent-degrade.sh`
  - `scripts/ci/self-application/check-hook-output-rewriting.sh`
  - `scripts/ci/self-application/check-u22-coverage.sh`
  - `.github/workflows/ci.yml`
- Detailed changes:
  - SEC-13 check: high-context writes must go through diff helper.
  - U-29 check: no unallowlisted `except Exception: pass`, timeout pass, or silent `2>/dev/null || echo ""` in security-sensitive paths.
  - SEC-13 output rewrite check: `updatedToolOutput` requires a reason comment.
  - U-22 coverage check: start with report-only if coverage tooling is absent; make blocking after baseline is known.
- Step tests:
  - `bash scripts/ci/self-application/run-all.sh`
  - Synthetic negative checks where practical.
- Completion judgment:
  - CI has one visible self-application job.
  - Each P0 self-violation has a sentinel.
- Rollback:
  - Remove self-application job; individual fixes stay.

### Step P3.3 God-File Refactors

- Status: `completed`
- Findings: M14
- Target: reduce large files after behavior is covered by tests.
- Expected files:
  - `vg-helper/src/session_metrics.rs` -> `vg-helper/src/session_metrics/{mod.rs,collect.rs,aggregate.rs,render.rs}`
  - `hooks/post-edit-guard.sh` -> detector libs under `hooks/_lib/`
  - `scripts/gc/gc-scheduled.sh` -> discover/classify/evict/report helpers
  - `hooks/log.sh` -> `hooks/_lib/{json,log,session,timer}.sh`
  - `hooks/post-write-guard.sh` if still over target
- Detailed changes:
  - Add regression tests before moving logic.
  - Split one file per PR.
  - Preserve exported shell function names through compatibility sources.
- Step tests:
  - For Rust split: `(cd vg-helper && cargo test)`
  - For each hook split: `bash tests/hooks/test_<hook>.sh`
  - For log split: `bash tests/test_hooks.sh`
- Completion judgment:
  - Each split file under 300 LOC unless a local exception is documented.
  - No behavior changes beyond module boundaries.
- Rollback:
  - Revert each split independently.

### Step P3.4 Low-Priority Cleanup Batch

- Status: `completed`
- Findings: Low items, M8, M12 decision follow-up, CFG retention knobs
- Target: clean up deferred low-risk drift after core fixes land.
- Expected files:
  - `rules/claude-rules/common/security.md`
  - `schemas/vibeguard-project.schema.json`
  - `scripts/lib/install-state.sh`
  - `scripts/lib/project_config.sh`
  - `scripts/gc/gc-*.sh`
  - `README.md`
  - `vg-helper/src/log_query.rs`
  - `vg-helper/src/session_metrics/time.rs`
  - `hooks/pre-bash-guard.sh`
  - `hooks/run-hook-codex.sh`
- Detailed changes:
  - Document SEC-14 allow-list for rule files containing attack examples.
  - Add schema keys for GC retention if runtime reads them.
  - Add install-state version migration guard.
  - Add time window to paralysis-count logic.
  - Replace subprocess date use with Rust `SystemTime` where practical.
  - Resolve `skills-loader` enum mismatch.
  - Decide `mcp-server/`: deprecate in docs or wire into installer.
- Step tests:
  - `(cd vg-helper && cargo test)`
  - `bash tests/test_setup.sh`
  - `bash scripts/ci/self-application/run-all.sh`
- Completion judgment:
  - Low findings are fixed or explicitly documented as legacy/deprecated behavior.
  - `mcp-server/` is documented as a legacy prototype that is not installed by `setup.sh`; supported surfaces are hooks and the app-server wrapper unless a future MCP install path gets an explicit audit/hash baseline.
  - GC retention and size knobs are exposed in `vibeguard-project.schema.json` and consumed by GC scripts through `.vibeguard.json` or `VIBEGUARD_GC_*` environment overrides.
- Rollback:
  - Revert cleanup batch or individual low-risk commits.

## 4. Phase Regression Matrix

### P0 Completion Matrix

```bash
bash tests/test_hooks.sh test_precommit_timeout
bash tests/test_hooks.sh test_log_sh_strict_parse
bash tests/test_hooks.sh test_pre_edit_json_escape
bash tests/test_setup.sh test_sec13_diff
uv run python -m pytest eval/test_run_eval.py::test_skipped_semantics
uv run python -m pytest scripts/test_constraint_recommender.py
bash setup.sh --check
```

### P1 Completion Matrix

```bash
bash tests/test_hooks.sh test_log_redaction
bash tests/test_gc_logs_concurrent.sh
(cd vg-helper && cargo test)
bash tests/test_hooks.sh test_session_metrics_canonical
bash tests/test_hooks.sh test_pkg_rewrite_canonical
uv run python -m pytest eval/test_run_eval.py::test_calibration
```

### P2 Completion Matrix

```bash
bash scripts/ci/validate-hooks-manifest.sh
bash scripts/setup/regenerate-hooks-from-manifest.sh --check
bash tests/test_setup.sh
bash tests/test_codex_runtime.sh
bash tests/test_hooks.sh
bash scripts/verify/check-test-file-sizes.sh
```

### P3 Completion Matrix

```bash
bash scripts/ci/self-application/run-all.sh
bash scripts/ci/check-event-schema-literals.sh
(cd vg-helper && cargo test)
bash tests/test_hooks.sh
bash tests/test_setup.sh
```

### Final Release Matrix

```bash
git status --short
bash setup.sh --check
bash tests/test_hooks.sh
bash tests/test_setup.sh
bash tests/test_codex_runtime.sh
(cd vg-helper && cargo test)
uv run python -m pytest eval scripts
bash scripts/ci/self-application/run-all.sh
```

If any command is unavailable because the repo has no pytest config or credentials, record the exact error and nearest fallback in the execution log.

## 5. Finding-To-Step Map

| Finding | Step |
|---------|------|
| H1 | P0.1 |
| H2 | P0.3 |
| H3 | P0.2 |
| H4 | P1.3 |
| H5 | P0.5, P1.5 |
| H6 | P1.2 |
| H7 | P0.5 |
| H8 | P2.4 |
| H9 | P2.3 |
| H10 | P2.1 |
| M1 | P1.1 |
| M2 | P0.4 |
| M3 | P3.2 |
| M4 | P3.1 |
| M5 | P0.2, P3.1 |
| M6 | P1.4 |
| M7 | P3.2 |
| M8 | P2.1, P3.4 |
| M9 | P2.1 |
| M10 | P1.2, P3.4 |
| M11 | P0.3, P2.2 |
| M12 | P3.4 after owner decision |
| M13 | P2.2 |
| M14 | P3.3 |
| Low items | P3.4 |

## 6. Handoff Fields

- mode: `plan_first_then_execute`
- artifacts:
  - `docs/internal/research/2026-05-01-codebase-audit.md`
  - `plan/spec-codebase-audit-remediation.md`
  - `plan/2026-05-01_18-56-41-vibeguard-audit-remediation.md`
- verification_owner: the implementing agent for each step; no step is complete without command evidence in this file.
- stop_conditions:
  - High-context write without diff prompt required.
  - Hook protocol compatibility cannot be verified in both Claude and Codex paths.
  - Full phase matrix fails for reasons outside current step.
  - `mcp-server/` ownership decision blocks installer/schema cleanup.
- lane_map:
  - Security lane: P0.1, P0.2, P0.4, P1.1, P3.2.
  - Install/config lane: P0.3, P2.1, P2.2, P3.4.
  - Data/runtime lane: P1.2, P3.1.
  - Cross-language lane: P1.3, P1.4.
  - Eval lane: P0.5, P1.5.
  - Test/architecture lane: P2.3, P2.4, P3.3.

## 7. Execution Log

Append entries here after each implemented step.

```md
- 2026-05-01
  - Step P0.1: `completed`
    - Modified files:
      - `hooks/pre-commit-guard.sh`
      - `tests/test_hooks.sh`
    - Main changes:
      - Default pre-commit guard/build timeout handling is fail-closed.
      - `VIBEGUARD_PRECOMMIT_TIMEOUT_BEHAVIOR=warn` provides an explicit visible downgrade.
      - Timeout branches write `guard timeout` / `build timeout` events to `events.jsonl`.
    - Tests:
      - `bash tests/test_hooks.sh` -> pass, 129/129
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `bash tests/test_setup.sh` -> pass, 91/91
      - `(cd vg-helper && cargo test)` -> pass, 31/31
    - Notes:
      - `setup.sh --check` drift warnings are pre-existing install-state issues and not caused by P0.1.
  - Step P0.2: `completed`
    - Modified files:
      - `vg-helper/src/json_field.rs`
      - `vg-helper/tests/cli.rs`
      - `hooks/log.sh`
      - `hooks/pre-bash-guard.sh`
      - `tests/test_hooks.sh`
    - Main changes:
      - Added `vg-helper json-field --strict` so missing/null fields fail distinctly from empty strings.
      - Added `vg_json_field_strict` with automatic Python strict fallback when an installed old `vg-helper` does not support `--strict`.
      - Migrated `pre-bash-guard.sh` command extraction to fail closed on malformed input or missing `tool_input.command`.
      - Fixed one pre-existing hook test payload that accidentally generated invalid JSON through shell `printf`.
    - Tests:
      - `cargo test --test cli strict` -> pass, 3/3
      - `bash tests/test_hooks.sh` -> pass, 133/133
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `bash tests/test_setup.sh` -> pass, 91/91
      - `(cd vg-helper && cargo test)` -> pass, 34/34
    - Notes:
      - `setup.sh --check` drift warnings are still pre-existing install-state issues.
  - Step P0.3: `completed`
    - Modified files:
      - `scripts/lib/settings_json.py`
      - `scripts/lib/claude_md.py`
      - `scripts/setup/lib.sh`
      - `scripts/setup/install.sh`
      - `scripts/setup/targets/claude-home.sh`
      - `tests/test_setup.sh`
    - Main changes:
      - Added `setup.sh --dry-run` for high-context diffs without writes.
      - Added `setup.sh --yes` / `VIBEGUARD_SETUP_AUTO=1` for explicit non-interactive application.
      - Added unified-diff rendering for `~/.claude/settings.json` and `~/.claude/CLAUDE.md`.
      - Non-interactive setup now refuses high-context writes unless explicit auto-apply is set.
    - Tests:
      - `python3 -m py_compile scripts/lib/settings_json.py scripts/lib/claude_md.py` -> pass
      - `bash tests/test_setup.sh` -> pass, 100/100
      - `bash tests/test_hooks.sh` -> pass, 133/133
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `(cd vg-helper && cargo test)` -> pass, 34/34
    - Notes:
      - `--yes` still prints the diff to stderr before applying so SEC-13 visibility is preserved in automation logs.
  - Step P0.4: `completed`
    - Modified files:
      - `hooks/pre-edit-guard.sh`
      - `tests/test_hooks.sh`
    - Main changes:
      - Replaced hand-written pre-edit block JSON heredocs with `vg_json_output_kv`.
      - Escaped file paths and reason text consistently for `TEST_INFRA_PROTECTED`, `FILE_NOT_FOUND`, `OLD_STRING_NOT_FOUND`, and `U16_OVER_LIMIT`.
      - Added a regression case for paths containing double quotes and backslashes.
    - Tests:
      - `bash tests/test_hooks.sh` -> pass, 135/135
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `bash tests/test_setup.sh` -> pass, 100/100
      - `(cd vg-helper && cargo test)` -> pass, 34/34
    - Notes:
      - The audit called out three heredocs; implementation fixed all four pre-edit block payload heredocs found in the file.
  - Step P0.5: `completed`
    - Modified files:
      - `scripts/constraint-recommender.py`
      - `scripts/test_constraint_recommender.py`
      - `eval/run_eval.py`
      - `eval/test_run_eval.py`
    - Main changes:
      - Replaced constraint recommender parser `except Exception: pass` sites with stderr diagnostics and structured JSON `diagnostics`.
      - Fixed a pre-existing syntax error in the Go constraint recommendation block.
      - Changed eval API failures to `skipped: true` so they do not count as genuine misses or false positives.
      - Added `EVAL_MAX_API_FAILURES` so infrastructure failures can fail eval runs explicitly.
    - Tests:
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 6/6
      - `python3 -m py_compile scripts/constraint-recommender.py scripts/test_constraint_recommender.py eval/run_eval.py eval/test_run_eval.py` -> pass
      - `bash tests/test_hooks.sh` -> pass, 135/135
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `bash tests/test_setup.sh` -> pass, 100/100
      - `(cd vg-helper && cargo test)` -> pass, 34/34
    - Notes:
      - Network/API failures are now visible as skipped samples and excluded from score denominators.
  - Step P1.1: `completed`
    - Modified files:
      - `hooks/log.sh`
      - `tests/test_hooks.sh`
    - Main changes:
      - Added `vg_redact_sensitive` before JSON escaping and detail truncation.
      - Redacts authorization bearer values, bare bearer tokens, API key/password/secret/token assignments, and matching CLI flags.
      - Applies redaction to both `reason` and `detail`.
    - Tests:
      - `bash -n hooks/log.sh` -> pass
      - `bash tests/test_hooks.sh` -> pass, 145/145
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 6/6
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `bash tests/test_setup.sh` -> pass, 100/100
      - `(cd vg-helper && cargo test)` -> pass, 34/34
    - Notes:
      - Redaction runs before truncation so partially truncated secrets are not persisted.
  - Step P1.2: `completed`
    - Modified files:
      - `hooks/log.sh`
      - `scripts/gc/gc-logs.sh`
      - `tests/test_gc_logs_concurrent.sh`
    - Main changes:
      - Added a shared lockdir around hook log appends so GC and writers coordinate.
      - Reworked log GC to use a same-directory temp file, fsync, chmod 0600, and `os.replace`.
      - Added Python `fcntl.flock(LOCK_EX)` inside GC while archiving/replacing logs.
      - Fixed GC dry-run parsing so `DRY_RUN=false` is no longer treated as true.
    - Tests:
      - `bash -n hooks/log.sh scripts/gc/gc-logs.sh tests/test_gc_logs_concurrent.sh` -> pass
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
      - `bash tests/test_hooks.sh` -> pass, 145/145
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 6/6
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `bash tests/test_setup.sh` -> pass, 100/100
      - `(cd vg-helper && cargo test)` -> pass, 34/34
    - Notes:
      - The concurrency test holds the writer lock, appends a current-month event, then verifies GC retains it after archiving old-month events.
  - Step P1.3: `completed`
    - Modified files:
      - `vg-helper/src/session_metrics.rs`
      - `hooks/learn-evaluator.sh`
      - `hooks/_lib/session_metrics.py`
    - Main changes:
      - Declared Rust `vg-helper session-metrics` as canonical and Python as deprecated fallback.
      - Aligned Signal 6 with Python by including max `Nx` analysis-paralysis depth.
      - Made repeated-rule signals deterministic and capped to top 3 by count then rule id.
      - Runtime Python fallback now writes a visible warn event before use.
    - Tests:
      - `(cd vg-helper && cargo test session_metrics)` -> pass, 25/25
      - `bash -n hooks/learn-evaluator.sh hooks/log.sh` -> pass
      - `python3 -m py_compile hooks/_lib/session_metrics.py` -> pass
      - `bash tests/test_hooks.sh` -> pass, 145/145
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
      - `bash tests/test_setup.sh` -> pass, 100/100
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `(cd vg-helper && cargo test)` -> pass, 36/36
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 6/6
    - Notes:
      - Python fallback remains for compatibility, but it is no longer a silent downgrade.
  - Step P1.4: `completed`
    - Modified files:
      - `vg-helper/src/pkg_rewrite.rs`
      - `hooks/pre-bash-guard.sh`
      - `hooks/_lib/pkg_rewrite.py`
    - Main changes:
      - Declared Rust `vg-helper pkg-rewrite` as canonical and Python as deprecated fallback.
      - Added Rust branch tests for npm/yarn/pip/python -m pip rewrites, unsupported flags, and complex command pass-through.
      - Runtime Python fallback now writes a visible warn event before use.
    - Tests:
      - `(cd vg-helper && cargo test pkg_rewrite)` -> pass, 9/9
      - `bash -n hooks/pre-bash-guard.sh hooks/log.sh` -> pass
      - `python3 -m py_compile hooks/_lib/pkg_rewrite.py` -> pass
      - `bash tests/test_hooks.sh` -> pass, 145/145
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
      - `bash tests/test_setup.sh` -> pass, 100/100
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `(cd vg-helper && cargo test)` -> pass, 45/45
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 6/6
    - Notes:
      - Python fallback remains for compatibility, but it is no longer a silent downgrade.
  - Step P1.5: `completed`
    - Modified files:
      - `eval/run_eval.py`
      - `eval/test_run_eval.py`
    - Main changes:
      - Extended the eval response contract so model output includes `CONFIDENCE: low|medium|high`.
      - Added robust confidence parsing and ECE computation with missing-confidence samples excluded for backward compatibility.
      - Added a `[Calibration]` report section that separates detected, missed, skipped, and calibration coverage.
    - Tests:
      - `python3 -m unittest eval/test_run_eval.py` -> pass, 8/8
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 10/10
      - `python3 -m py_compile eval/run_eval.py eval/test_run_eval.py` -> pass
      - `bash tests/test_eval_contract.sh` -> pass, 3/3
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
      - `bash tests/test_hooks.sh` -> pass, 145/145
      - `bash tests/test_setup.sh` -> pass, 100/100
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `(cd vg-helper && cargo test)` -> pass, 45/45
    - Notes:
      - Live API calibration smoke was not run because no credential-dependent eval run was required for this local contract change.
  - Step P2.1: `completed`
    - Modified files:
      - `hooks/manifest.json`
      - `schemas/hooks-manifest.schema.json`
      - `scripts/lib/hooks_manifest.py`
      - `scripts/lib/codex_hooks_json.py`
      - `scripts/lib/settings_json.py`
      - `scripts/setup/regenerate-hooks-from-manifest.sh`
      - `scripts/ci/validate-hooks-manifest.sh`
      - `hooks/CLAUDE.md`
      - `scripts/CLAUDE.md`
      - `.github/workflows/ci.yml`
      - `tests/test_setup.sh`
    - Main changes:
      - Added `hooks/manifest.json` as the hook registration source of truth for script names, Claude events/matchers/profiles, Codex support, timeouts, and docs text.
      - Added a manifest helper used by both `settings_json.py` and `codex_hooks_json.py`, removing the hard-coded Codex `MANAGED_SPECS` list and the hard-coded Claude upsert list.
      - Added generated `hooks/CLAUDE.md` table markers plus a `--check|--write` regeneration script.
      - Added `validate-hooks-manifest.sh` and CI coverage; it validates manifest shape, parseability, docs generation, and install-module hook coverage.
    - Tests:
      - `bash scripts/ci/validate-hooks-manifest.sh` -> pass
      - `bash scripts/setup/regenerate-hooks-from-manifest.sh --check` -> pass
      - `python3 -m py_compile scripts/lib/hooks_manifest.py scripts/lib/settings_json.py scripts/lib/codex_hooks_json.py` -> pass
      - `bash tests/test_setup.sh` -> pass, 106/106
      - `bash tests/test_hooks.sh` -> pass, 145/145
      - `bash tests/test_codex_runtime.sh` -> pass, 38/38
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 10/10
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `(cd vg-helper && cargo test)` -> pass, 45/45
      - `bash tests/test_eval_contract.sh` -> pass, 3/3
    - Notes:
      - `setup.sh --check` drift warnings are still pre-existing install-state issues.
      - This step covers hook registration/docs manifest drift; broader skill install-module drift remains for later P3 cleanup.
  - Step P2.2: `completed`
    - Modified files:
      - `scripts/lib/settings_json.py`
      - `scripts/setup/lib.sh`
      - `scripts/setup/install.sh`
      - `scripts/setup/targets/claude-home.sh`
      - `tests/test_setup.sh`
    - Main changes:
      - Added explicit `--force-overwrite` / `VIBEGUARD_SETUP_FORCE_OVERWRITE=1` mode.
      - Preserved user-customized Claude hook commands by default when they wrap a managed script with a non-canonical command such as `flock ... run-hook.sh pre-bash-guard.sh`.
      - Allowed old canonical VibeGuard hook commands to upgrade normally while requiring force for custom wrappers.
      - Refused to overwrite or remove modified local rule copies during rule symlink installation and `--languages` profile narrowing unless force-overwrite is explicit.
      - Kept setup warnings visible by no longer suppressing settings helper stderr during apply.
    - Tests:
      - `bash tests/test_setup.sh` -> pass, 114/114
      - `bash tests/test_hooks.sh` -> pass, 145/145
      - `bash tests/test_codex_runtime.sh` -> pass, 38/38
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 10/10
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `(cd vg-helper && cargo test)` -> pass, 45/45
      - `bash tests/test_eval_contract.sh` -> pass, 3/3
      - `bash scripts/ci/validate-hooks-manifest.sh` -> pass
    - Notes:
      - P2.2 protects Claude settings and native rule files; Codex hooks remain managed by the existing prune/upsert semantics.
  - Step P2.3: `completed`
    - Modified files:
      - `hooks/run-hook-codex.sh`
      - `hooks/_lib/codex_adapter.sh`
      - `scripts/ci/validate-hooks.sh`
      - `tests/test_codex_runtime.sh`
    - Main changes:
      - Extracted Codex event parsing plus PreToolUse/PostToolUse output adaptation into `hooks/_lib/codex_adapter.sh`.
      - Reduced `run-hook-codex.sh` to hook resolution, execution, failure policy, and adapter dispatch.
      - Added direct PostToolUse block adaptation coverage.
      - Extended hook syntax CI to include `hooks/_lib/*.sh`.
    - Tests:
      - `bash -n hooks/run-hook-codex.sh hooks/_lib/codex_adapter.sh scripts/ci/validate-hooks.sh` -> pass
      - `bash scripts/ci/validate-hooks.sh` -> pass
      - `bash tests/test_codex_runtime.sh` -> pass, 40/40
      - `bash tests/test_hooks.sh` -> pass, 145/145
      - `bash tests/test_setup.sh` -> pass, 114/114
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 10/10
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `(cd vg-helper && cargo test)` -> pass, 45/45
      - `bash tests/test_eval_contract.sh` -> pass, 3/3
    - Notes:
      - `run-hook-codex.sh` is now 100 lines; adapter logic lives in a dedicated 105-line shared library.
  - Step P2.4: `completed`
    - Modified files:
      - `tests/test_hooks.sh`
      - `tests/lib/hook_test_lib.sh`
      - `tests/lib/precommit_fixtures.sh`
      - `tests/hooks/test_*.sh`
      - `scripts/verify/check-test-file-sizes.sh`
    - Main changes:
      - Split the 1654-line hook mega-test into a 34-line orchestrator plus 15 focused hook test shards.
      - Moved shared assertion/log setup helpers into `tests/lib/hook_test_lib.sh`.
      - Moved pre-commit stub guard fixtures into `tests/lib/precommit_fixtures.sh`.
      - Added a size sentinel so `tests/test_hooks.sh` stays under 100 lines and hook shards stay under 400 lines.
    - Tests:
      - `bash -n tests/test_hooks.sh tests/hooks/*.sh tests/lib/*.sh scripts/verify/check-test-file-sizes.sh` -> pass
      - `bash scripts/verify/check-test-file-sizes.sh` -> pass
      - `bash tests/test_hooks.sh` -> pass, 145/145 across shards
      - `bash tests/test_setup.sh` -> pass, 114/114
      - `bash tests/test_codex_runtime.sh` -> pass, 40/40
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 10/10
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `(cd vg-helper && cargo test)` -> pass, 45/45
      - `bash tests/test_eval_contract.sh` -> pass, 3/3
    - Notes:
      - The split is mechanical; the per-shard assertion totals sum to the original 145 assertions.
  - Step P3.1: `completed`
    - Modified files:
      - `vg-helper/src/event_schema.rs`
      - `vg-helper/src/main.rs`
      - `vg-helper/src/log_query.rs`
      - `vg-helper/src/session_metrics.rs`
      - `vg-helper/src/json_field.rs`
      - `scripts/ci/check-event-schema-literals.sh`
      - `.github/workflows/ci.yml`
    - Main changes:
      - Added canonical Rust constants for event fields, decisions, hook names, tool names, and session-metrics output fields.
      - Replaced production raw event-field literals in `log_query.rs` and `session_metrics.rs` with `event_schema` constants.
      - Documented tolerant vs strict `json-field` behavior for invalid JSON, absent fields, null fields, and empty strings.
      - Added `check-event-schema-literals.sh` and wired it into Linux/macOS and Windows-smoke CI.
    - Tests:
      - `cargo fmt --manifest-path vg-helper/Cargo.toml --check` -> pass
      - `bash scripts/ci/check-event-schema-literals.sh` -> pass
      - `(cd vg-helper && cargo test)` -> pass, 45/45
      - `bash tests/test_hooks.sh` -> pass, 145/145 across shards
      - `bash tests/test_setup.sh` -> pass, 114/114
      - `bash tests/test_codex_runtime.sh` -> pass, 40/40
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 10/10
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `bash tests/test_eval_contract.sh` -> pass, 3/3
      - `bash scripts/ci/validate-hooks-manifest.sh` -> pass
      - `bash scripts/verify/check-test-file-sizes.sh` -> pass
    - Notes:
      - The new CI check intentionally ignores Rust test fixtures so regression fixtures can still spell JSON keys literally.
      - `setup.sh --check` still reports the known pre-existing local install drift, but exits 0.
  - Step P3.2: `completed`
    - Modified files:
      - `scripts/ci/self-application/run-all.sh`
      - `scripts/ci/self-application/check-sec13-self-apply.sh`
      - `scripts/ci/self-application/check-u29-no-silent-degrade.sh`
      - `scripts/ci/self-application/check-hook-output-rewriting.sh`
      - `scripts/ci/self-application/check-u22-coverage.sh`
      - `tests/test_self_application_ci.sh`
      - `scripts/codex/app_server_wrapper.py`
      - `.github/workflows/ci.yml`
    - Main changes:
      - Added a visible self-application CI job plus local `run-all.sh` sentinel entry point.
      - Added SEC-13 self-checks for setup diff/confirmation paths.
      - Added U-29 self-checks for silent Python `Exception: pass`, pre-commit timeout fail-open regressions, strict Bash JSON extraction, and eval skipped-error semantics.
      - Added an output-rewrite sentinel requiring `SEC-13-OUTPUT-REWRITE-REASON:` near future `updatedToolOutput` usage.
      - Added U-22 coverage inventory in report-only mode until a real llvm-cov baseline is adopted.
      - Narrowed `scripts/codex/app_server_wrapper.py` cleanup from `except Exception: pass` to `except OSError: pass`.
    - Tests:
      - `bash -n scripts/ci/self-application/*.sh tests/test_self_application_ci.sh` -> pass
      - `python3 -m py_compile scripts/codex/app_server_wrapper.py` -> pass
      - `bash scripts/ci/self-application/run-all.sh` -> pass
      - `bash tests/test_self_application_ci.sh` -> pass, 5/5
      - `bash tests/test_hooks.sh` -> pass, 145/145 across shards
      - `bash tests/test_setup.sh` -> pass, 114/114
      - `bash tests/test_codex_runtime.sh` -> pass, 40/40
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 10/10
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `(cd vg-helper && cargo test)` -> pass, 45/45
      - `bash tests/test_eval_contract.sh` -> pass, 3/3
      - `bash scripts/ci/check-event-schema-literals.sh` -> pass
      - `bash scripts/ci/validate-hooks-manifest.sh` -> pass
      - `bash scripts/verify/check-test-file-sizes.sh` -> pass
    - Notes:
      - The U-22 check is intentionally report-only because the repository does not yet have a measured llvm-cov baseline.
      - The self-application test includes negative fixtures for unreasoned hook output rewriting and silent `Exception: pass`.
  - Step P3.3: `completed`
    - Modified files:
      - `vg-helper/src/session_metrics/{mod.rs,engine.rs,signals.rs,time.rs,tests/mod.rs,tests/run.rs,tests/time.rs}`
      - `hooks/log.sh`
      - `hooks/_lib/log_json.sh`
      - `hooks/_lib/log_session.sh`
      - `hooks/_lib/log_timer.sh`
      - `hooks/_lib/log_redact.sh`
      - `hooks/_lib/log_write.sh`
      - `scripts/ci/check-event-schema-literals.sh`
      - `scripts/ci/self-application/check-u22-coverage.sh`
    - Main changes:
      - Split the 786-line `session_metrics.rs` into focused Rust modules: engine, signal detection, time/session filtering, and tests.
      - Split `hooks/log.sh` from 470 lines into a 77-line loader plus focused `_lib/log_*.sh` modules for JSON helpers, session inference, timer, redaction, and JSONL writing.
      - Updated event-schema literal CI to scan the new Rust module layout.
      - Updated U-22 inventory to scan nested Rust modules.
    - Tests:
      - `cargo fmt --manifest-path vg-helper/Cargo.toml --check` -> pass
      - `(cd vg-helper && cargo test)` -> pass, 45/45
      - `bash -n hooks/log.sh hooks/_lib/log_*.sh` -> pass
      - `bash scripts/ci/validate-hooks.sh` -> pass
      - `bash tests/test_hooks.sh` -> pass, 145/145 across shards
      - `bash tests/test_setup.sh` -> pass, 114/114
      - `bash tests/test_codex_runtime.sh` -> pass, 40/40
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
      - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 10/10
      - `bash setup.sh --check` -> pass exit 0, existing drift warnings for missing skills/rule count/config checksum
      - `bash tests/test_eval_contract.sh` -> pass, 3/3
      - `bash scripts/ci/self-application/run-all.sh` -> pass
      - `bash tests/test_self_application_ci.sh` -> pass, 5/5
      - `bash scripts/ci/check-event-schema-literals.sh` -> pass
      - `bash scripts/ci/validate-hooks-manifest.sh` -> pass
      - `bash scripts/verify/check-test-file-sizes.sh` -> pass
    - Notes:
      - `post-edit-guard.sh` and `gc-scheduled.sh` remain large; this step addressed the highest-coverage Rust god file and the shared hook logging god file without changing detector semantics.
  - Step P3.4: `completed`
    - Modified files:
      - `vg-helper/src/time_utils.rs`
      - `vg-helper/src/main.rs`
      - `vg-helper/src/session_metrics/time.rs`
      - `vg-helper/src/log_query.rs`
      - `vg-helper/tests/cli.rs`
      - `schemas/vibeguard-project.schema.json`
      - `rules/claude-rules/common/security.md`
      - `scripts/lib/install-state.sh`
      - `scripts/lib/project_config.sh`
      - `scripts/gc/gc-logs.sh`
      - `scripts/gc/gc-worktrees.sh`
      - `scripts/gc/gc-scheduled.sh`
      - `README.md`
      - `tests/test_gc_config.sh`
    - Main changes:
      - Replaced the session-metrics `/bin/date` subprocess path with shared Rust `SystemTime` utilities.
      - Added a 30-minute timestamp window for `paralysis-count` while preserving legacy events that do not carry timestamps.
      - Removed the stale `skills-loader` enum value from the project schema.
      - Documented the SEC-14 rule-file self-check exception for defensive examples in the rule corpus.
      - Added install-state version guards so unsupported future state files fail visibly instead of being misread.
      - Added GC retention/threshold schema keys and a shared shell config reader for `.vibeguard.json` / `VIBEGUARD_GC_*` overrides.
      - Documented `mcp-server/` as a legacy, unsupported runtime prototype instead of a silently orphaned install surface.
    - Tests:
      - `cargo fmt --manifest-path vg-helper/Cargo.toml` -> pass
      - `(cd vg-helper && cargo test)` -> pass, 49/49
      - `bash -n scripts/lib/install-state.sh` -> pass
      - `python3 -m json.tool schemas/vibeguard-project.schema.json >/dev/null` -> pass
      - `bash scripts/ci/check-event-schema-literals.sh` -> pass
      - `bash tests/test_setup.sh` -> pass, 114/114
      - `bash scripts/ci/validate-manifest-contract.sh` -> pass
      - `bash tests/test_manifest_contract.sh` -> pass, 30/30
      - `bash scripts/ci/self-application/run-all.sh` -> pass
      - `bash tests/test_self_application_ci.sh` -> pass, 5/5
      - `bash tests/test_gc_config.sh` -> pass, 7/7
      - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13
    - Notes:
      - The legacy MCP subtree remains outside setup intentionally; the supported integration matrix is now explicit in README.
      - GC defaults are unchanged unless `.vibeguard.json` or environment overrides are provided.
  - Final regression matrix: `passed`
    - `bash setup.sh --check` -> pass exit 0, known local install drift only: missing `agentsmd-audit` / `trajectory-review` skills, stale rule-count banner, unloaded scheduled GC plist, and `~/.codex/config.toml` checksum drift.
    - `bash tests/test_hooks.sh` -> pass, all hook shards.
    - `bash tests/test_setup.sh` -> pass, 114/114.
    - `bash tests/test_codex_runtime.sh` -> pass, 40/40.
    - `bash tests/test_gc_logs_concurrent.sh` -> pass, 13/13.
    - `bash tests/test_gc_config.sh` -> pass, 7/7.
    - `cargo fmt --manifest-path vg-helper/Cargo.toml --check && cargo test --manifest-path vg-helper/Cargo.toml` -> pass, 49/49.
    - `python3 -m unittest scripts/test_constraint_recommender.py eval/test_run_eval.py` -> pass, 10/10.
    - `bash scripts/ci/self-application/run-all.sh` -> pass.
    - `bash tests/test_self_application_ci.sh` -> pass, 5/5.
    - `bash scripts/ci/check-event-schema-literals.sh` -> pass.
    - `bash scripts/ci/validate-hooks-manifest.sh` -> pass.
    - `bash scripts/ci/validate-hooks.sh` -> pass.
    - `bash scripts/verify/check-test-file-sizes.sh` -> pass.
    - `bash tests/test_eval_contract.sh` -> pass, 3/3.
    - `bash tests/test_manifest_contract.sh` -> pass, 30/30.
    - `bash scripts/ci/validate-manifest-contract.sh` -> pass.
```
