---
mode: plan
cwd: /Users/lifcc/Desktop/code/AI/tools/vibeguard
task: Converge latest main architecture debt into a single-source-of-truth install/runtime/verification model
complexity: complex
planning_method: plan-flow
created_at: 2026-04-19T00:15:39+08:00
source_ref: origin/main@17504d0
---

# VibeGuard main architecture convergence plan

- Planned version: v1
- Applicable repository: `/Users/lifcc/Desktop/code/AI/tools/vibeguard`
- Execution mode: analyze root cause -> change one step -> run step tests -> update plan -> continue

## 0. Execution constraints (DoR)

- Objective: remove the current split-brain design across rule metadata, install/runtime behavior, client capability handling, and verification gates without adding new runtime dependencies.
- Compatibility: required
- Submission strategy: milestone
- Guardrails:
  - No new user-facing feature work until `P0` fail-open/runtime issues are closed.
  - Prefer generated or manifest-driven surfaces over more prose duplication.
  - Keep client capability differences explicit instead of silently degrading behavior.
- Test strategy:
  - Step level: at least 1 targeted contract test plus 1 nearby health check for each step.
  - Final: full repo regression matrix on supported platforms plus deterministic manifest/document validation.

## 1. Analysis results (before changes)

- Architecture inventory summary:
  - Install entry: `setup.sh`, `scripts/setup/install.sh`, `scripts/setup/check.sh`, `scripts/setup/clean.sh`
  - Client target adapters: `scripts/setup/targets/claude-home.sh`, `scripts/setup/targets/codex-home.sh`
  - Runtime adapters: `hooks/run-hook.sh`, `hooks/run-hook-codex.sh`, `scripts/codex/app_server_wrapper.py`
  - Metadata surfaces: `rules/claude-rules/**`, `rules/*.md`, `docs/rule-reference.md`, `schemas/install-modules.json`, `schemas/vibeguard-project.schema.json`
  - Verification surfaces: `.github/workflows/ci.yml`, `tests/test_hooks.sh`, `tests/test_setup.sh`, `tests/run_precision.sh`, `eval/run_eval.py`
  - Product/workflow surfaces: `README.md`, `docs/README_CN.md`, `docs/internal/history/spec.md`, `skills/vibeguard/SKILL.md`, `agents/dispatcher.md`, `workflows/**`
- Root-cause findings:

| id | category | files and symbols | evidence | impact | risk | suggested convergence |
|----|----------|-------------------|----------|--------|------|-----------------------|
| F1 | fail-open runtime adapter | `scripts/codex/app_server_wrapper.py::on_server_notification`, `hooks/post-build-check.sh`, `hooks/learn-evaluator.sh` | post-turn hooks run but outputs are discarded, so Codex app-server never sees stop/build feedback | critical | high | make hook results first-class protocol events and expose degraded-mode explicitly |
| F2 | split install contract | `scripts/lib/settings_json.py`, `scripts/lib/codex_hooks_json.py`, `schemas/install-modules.json`, `schemas/vibeguard-project.schema.json` | profile names and module composition diverge across code, schema, and docs | high | high | define one canonical install/capability manifest and generate/validate secondary surfaces |
| F3 | runtime artifact split | `scripts/setup/install.sh`, `hooks/run-hook.sh`, `scripts/install-hook.sh`, `scripts/project-init.sh` | Claude/Codex use installed snapshot while Git hooks still point at live repo | high | medium | unify all runtime entrypoints on installed snapshot plus shared wrapper stack |
| F4 | verification false confidence | `.github/workflows/ci.yml`, `tests/run_precision.sh`, `tests/test_hooks.sh`, `eval/run_eval.py`, `scripts/benchmark.sh` | Windows lane mostly skips behavior tests, precision never fails CI, rewrite path is provisioned but skipped, eval reads `$HOME` | high | medium | convert CI from report-first to contract-first and pin eval inputs to repo snapshot |
| F5 | product/document surface sprawl | `README.md`, `docs/README_CN.md`, `docs/internal/history/spec.md`, `skills/vibeguard/SKILL.md`, `agents/dispatcher.md`, `workflows/**` | planning and routing are duplicated across too many top-level surfaces | medium | medium | separate canonical contract from generated/localized/preset surfaces |

## 2. Detailed steps

### Phase P0 Runtime correctness first

### Step P0.1 Define and codify the client capability matrix

- status: `completed`
- Target: create a single capability source that states what Claude, Codex CLI, Codex app-server, and Git hooks can actually support.
- Expected changes to files:
  - `schemas/install-modules.json`
  - `scripts/setup/targets/codex-home.sh`
  - `scripts/lib/codex_hooks_json.py`
  - `README.md`
  - `docs/README_CN.md`
- Detailed changes:
  - Add a canonical capability table covering hook events, `updatedInput`, post-turn feedback, and profile semantics per client.
  - Remove ambiguous wording that implies Claude and Codex share the same profile behavior when they do not.
  - Make unsupported features explicit and testable rather than silently omitted.
- step-level test command:
  - `python3 -m py_compile scripts/lib/codex_hooks_json.py`
  - `bash tests/test_setup.sh`
- Completion judgment:
  - One source defines per-client capability and profile behavior.
  - Docs and setup code reference the same capability model.

### Step P0.2 Fix Codex app-server post-turn fail-open behavior

- status: `completed`
- Target: ensure post-turn hook outputs are delivered back to the client instead of being computed and discarded.
- Expected changes to files:
  - `scripts/codex/app_server_wrapper.py`
  - `hooks/post-build-check.sh`
  - `hooks/learn-evaluator.sh`
  - `tests/test_hooks.sh`
  - `tests/test_setup.sh`
- Detailed changes:
  - Translate stop/build/learn hook results into outbound app-server notifications.
  - Preserve hook severity and message content in the adapter rather than dropping `HookResult`.
  - Add regression coverage for post-turn feedback flow.
- step-level test command:
  - `python3 -m py_compile scripts/codex/app_server_wrapper.py`
  - `bash tests/test_hooks.sh`
- Completion judgment:
  - Codex app-server path surfaces post-turn warnings/stop reasons to the client.
  - No hook result is silently discarded on the supported path.

### Step P0.3 Replace process-ancestry session guessing with explicit runtime context

- status: `completed`
- Target: stop deriving hook identity from `ps` heuristics when the adapter already knows thread/session context.
- Expected changes to files:
  - `scripts/codex/app_server_wrapper.py`
  - `hooks/log.sh`
  - `hooks/analysis-paralysis-guard.sh`
  - `hooks/post-build-check.sh`
  - `tests/test_hook_health.sh`
- Detailed changes:
  - Pass stable client/thread/turn/session env vars into hook subprocesses.
  - Make log-based counters consume explicit session identifiers.
  - Narrow tail-scan logic so it keys off real session context, not guessed parent ancestry.
- step-level test command:
  - `bash tests/test_hook_health.sh`
  - `bash tests/test_hooks.sh`
- Completion judgment:
  - Hook metrics and escalation logic use explicit adapter context.
  - Session attribution no longer depends on local process ancestry.

### Phase P1 Contract and metadata convergence

### Step P1.1 Introduce a canonical manifest for rules, profiles, and install modules

- status: `completed`
- Target: create one authoritative manifest from which rule metadata, profile composition, and suppressible IDs can be derived.
- Expected changes to files:
  - `schemas/install-modules.json`
  - `schemas/vibeguard-project.schema.json`
  - `rules/claude-rules/**`
  - `scripts/verify/doc-freshness-check.sh`
  - `scripts/setup/**`
- Detailed changes:
  - Define canonical entities: rule id, title, severity, scope, profile/module membership, guard mapping, suppressibility.
  - Remove undefined or impossible module references such as `hooks-strict`.
  - Normalize profile vocabulary so install/runtime/schema/docs use the same names.
- step-level test command:
  - `bash scripts/verify/doc-freshness-check.sh --strict`
  - `bash tests/test_setup.sh`
- Completion judgment:
  - Profile and module definitions are machine-verifiable and consistent.
  - Secondary surfaces stop inventing their own profile semantics.

### Step P1.2 Split repository consistency checks from install-state checks

- status: `completed`
- Target: make repository audits deterministic and independent from a contributor's local `$HOME` state.
- Expected changes to files:
  - `scripts/verify/doc-freshness-check.sh`
  - `scripts/setup/check.sh`
  - `scripts/setup/targets/claude-home.sh`
  - `README.md`
- Detailed changes:
  - Separate repo-local graph validation from installed-rule drift inspection.
  - Ensure `--check` is read-only and does not mutate `~/.claude/CLAUDE.md`.
  - Add a dedicated repair path for any mutable drift remediation.
- step-level test command:
  - `bash tests/test_setup.sh`
  - `bash scripts/verify/doc-freshness-check.sh --strict`
- Completion judgment:
  - Repo validation gives the same answer on different machines for the same commit.
  - `setup.sh --check` has no side effects.

### Step P1.3 Make Codex and Claude config mutation structured and portable

- status: `completed`
- Target: eliminate shell text-edit drift in user config files.
- Expected changes to files:
  - `scripts/setup/targets/codex-home.sh`
  - `scripts/lib/settings_json.py`
  - `scripts/lib/codex_hooks_json.py`
  - `tests/test_setup.sh`
- Detailed changes:
  - Move `config.toml` mutation into a structured helper instead of `sed -i ''`.
  - Keep JSON/TOML writes atomic and verifiable.
  - Fail install when required flags or managed hooks cannot be confirmed.
- step-level test command:
  - `python3 -m py_compile scripts/lib/settings_json.py scripts/lib/codex_hooks_json.py`
  - `bash tests/test_setup.sh`
- Completion judgment:
  - Install behavior is portable across macOS/Linux for existing user config files.
  - Setup does not report success when required features remain disabled.

### Phase P2 Verification and surface reduction

### Step P2.1 Turn CI into a true contract gate

- status: `completed`
- Target: make the highest-risk paths fail CI when they regress.
- Expected changes to files:
  - `.github/workflows/ci.yml`
  - `tests/run_precision.sh`
  - `tests/test_hooks.sh`
  - `scripts/benchmark.sh`
  - `tests/test_precision_tracker.sh`
- Detailed changes:
  - Convert precision into metrics + threshold gate instead of metrics-only.
  - Enable the `updatedInput` rewrite branch in CI.
  - Either add real behavioral Windows checks or explicitly downgrade Windows from required support.
  - Add missing contract coverage for wrappers and scorecard paths.
- step-level test command:
  - `bash tests/run_precision.sh --all --csv`
  - `bash tests/test_hooks.sh`
  - `bash tests/test_precision_tracker.sh`
- Completion judgment:
  - CI red/green status tracks actual regression risk instead of report generation.
  - The command rewrite path is exercised in automation.

### Step P2.2 Pin evals and benchmarks to the repository snapshot

- status: `completed`
- Target: make model/rule evaluation reproducible from the checked-out repo rather than local installed state.
- Expected changes to files:
  - `eval/run_eval.py`
  - `scripts/benchmark.sh`
  - `docs/internal/benchmarks/benchmark-design.md`
  - `.github/workflows/ci.yml`
- Detailed changes:
  - Load rules and prompts from repo-managed inputs by default.
  - Add a deterministic subset suitable for CI smoke evaluation.
  - Document the difference between local exploratory eval and repo-gated eval.
- step-level test command:
  - `python3 -m py_compile eval/run_eval.py`
  - `bash scripts/benchmark.sh --mode=fast`
- Completion judgment:
  - Eval behavior is reproducible from the repo snapshot.
  - Benchmarks stop hiding execution failures behind reporting output.

### Step P2.3 Reduce product surface duplication and make one canonical workflow path

- status: `completed`
- Target: separate core enforcement runtime from optional workflow presets and reduce documentation drift.
- Expected changes to files:
  - `README.md`
  - `docs/README_CN.md`
  - `docs/internal/history/spec.md`
  - `skills/vibeguard/SKILL.md`
  - `agents/dispatcher.md`
  - `workflows/**`
- Detailed changes:
  - Declare one canonical lifecycle for planning/execution and treat workflow variants as presets.
  - Split docs into canonical, generated, and localized responsibilities.
  - Reframe README around `VibeGuard Core` vs `VibeGuard Workflows`.
- step-level test command:
  - `bash scripts/ci/validate-doc-paths.sh`
  - `bash scripts/ci/validate-doc-command-paths.sh`
  - `bash scripts/verify/doc-freshness-check.sh --strict`
- Completion judgment:
  - New contributors can identify one primary flow and one canonical contract.
  - Command tables and workflow descriptions are no longer hand-maintained in multiple places.

## 3. Regression test matrix

- After P0:
  - `bash tests/test_hooks.sh`
  - `bash tests/test_setup.sh`
  - `bash tests/test_hook_health.sh`
- After P1:
  - `bash scripts/verify/doc-freshness-check.sh --strict`
  - `bash tests/test_setup.sh`
  - `bash scripts/ci/validate-doc-paths.sh`
- After P2:
  - `bash tests/run_precision.sh --all --csv`
  - `bash tests/test_precision_tracker.sh`
  - `bash tests/unit/run_all.sh`
  - `bash tests/test_rust_guards.sh`
  - `bash scripts/benchmark.sh --mode=fast`
- Final supported-platform matrix:
  - `bash tests/test_hooks.sh`
  - `bash tests/test_setup.sh`
  - `bash tests/test_hook_health.sh`
  - `bash tests/run_precision.sh --all --csv`
  - `bash tests/unit/run_all.sh`
  - `bash tests/test_rust_guards.sh`
  - `bash scripts/verify/doc-freshness-check.sh --strict`
  - `bash scripts/ci/validate-doc-paths.sh`
  - `bash scripts/ci/validate-doc-command-paths.sh`

## 4. Milestone acceptance criteria

- P0 accepted when:
  - Codex app-server no longer drops post-turn hook feedback.
  - Session attribution and escalation logic use explicit runtime context.
  - Capability differences are declared instead of silently skipped.
- P1 accepted when:
  - One canonical manifest drives profile/module/rule semantics.
  - Repo validation is deterministic and `setup.sh --check` is read-only.
  - Config mutation is portable and structured.
- P2 accepted when:
  - CI meaningfully blocks high-risk regressions.
  - Eval and benchmark flows are repo-snapshot based.
  - README/doc/workflow surfaces reduce to one primary contract plus documented presets.

## 5. Execution Log

- 2026-04-19
  - Plan authored: `completed`
    - Evidence:
      - Based on latest `origin/main` audit at `17504d0`
      - Integrated five parallel review lanes: install/runtime, rule metadata, hook runtime, verification, and product cohesion
    - Next recommended implementation step:
      - `P0.1 Define and codify the client capability matrix`
  - Step P0: `completed`
    - Modified files:
      - `scripts/codex/app_server_wrapper.py`
      - `hooks/run-hook-codex.sh`
      - `scripts/setup/targets/codex-home.sh`
      - `README.md`
      - `docs/README_CN.md`
      - `tests/test_codex_runtime.sh`
      - `.github/workflows/ci.yml`
    - Main changes:
      - Added explicit app-server feedback attachment on `turn/completed` so stop/build/learn hook results are no longer dropped.
      - Propagated stable `session/thread/turn` context from the app-server adapter into hook subprocesses.
      - Replaced silent Codex CLI `updatedInput` loss with an explicit suggestion message.
      - Documented the current Codex capability boundary in setup output and user-facing docs.
      - Added a dedicated Codex runtime regression test and wired it into non-Windows CI.
    - Execute tests:
      - `python3 -m py_compile scripts/codex/app_server_wrapper.py` -> pass
      - `bash tests/test_codex_runtime.sh` -> pass
      - `bash tests/test_hook_health.sh` -> pass
      - `bash tests/test_setup.sh` -> pass
      - `bash scripts/ci/validate-doc-command-paths.sh` -> pass
      - `bash scripts/ci/validate-doc-paths.sh` -> fail before cleanup, then fixed by updating the allowlist and removing non-PR-only path references
  - Step P1: `completed`
    - Modified files:
      - `schemas/install-modules.json`
      - `schemas/vibeguard-project.schema.json`
      - `scripts/lib/vibeguard_manifest.py`
      - `scripts/lib/codex_config_toml.py`
      - `scripts/setup/lib.sh`
      - `scripts/setup/install.sh`
      - `scripts/setup/targets/claude-home.sh`
      - `scripts/setup/targets/codex-home.sh`
      - `scripts/verify/doc-freshness-check.sh`
      - `docs/rule-reference.md`
      - `tests/test_setup.sh`
      - `tests/test_manifest_contract.sh`
    - Main changes:
      - Promoted `schemas/install-modules.json` into the canonical install/profile contract and removed stale entries such as `hooks-strict` and auto-installed `skills-loader`.
      - Added a manifest helper plus a structured Codex TOML helper so profile/schema/config drift can be validated and updated from one place.
      - Made `setup.sh --check` read-only and switched `doc-freshness` to repo-only deterministic validation.
    - Execute tests:
      - `python3 scripts/lib/vibeguard_manifest.py validate` -> pass
      - `bash tests/test_manifest_contract.sh` -> pass
      - `bash tests/test_setup.sh` -> pass
      - `bash scripts/verify/doc-freshness-check.sh --strict` -> pass
      - `bash scripts/ci/validate-manifest-contract.sh` -> pass
  - Step P2: `completed`
    - Modified files:
      - `.github/workflows/ci.yml`
      - `.vibeguard-doc-paths-allowlist`
      - `eval/run_eval.py`
      - `scripts/benchmark.sh`
      - `scripts/ci/validate-manifest-contract.sh`
      - `scripts/ci/validate-precision-thresholds.sh`
      - `README.md`
      - `docs/README_CN.md`
      - `docs/internal/history/spec.md`
      - `skills/vibeguard/SKILL.md`
      - `agents/dispatcher.md`
      - `tests/test_eval_contract.sh`
    - Main changes:
      - Split Unix behavioral CI from Windows smoke coverage, enabled rewrite-path testing, and added manifest/eval/precision contract gates.
      - Switched eval and benchmark defaults to the checked-out repository snapshot instead of `$HOME` state.
      - Clarified `VibeGuard Core` vs `VibeGuard Workflows` and pointed historical surfaces back to canonical sources.
    - Execute tests:
      - `bash tests/test_eval_contract.sh` -> pass
      - `VIBEGUARD_TEST_UPDATED_INPUT=1 bash tests/test_hooks.sh` -> pass
      - `bash tests/test_precision_tracker.sh` -> pass
      - `bash scripts/ci/validate-precision-thresholds.sh` -> pass
      - `bash scripts/ci/validate-doc-paths.sh` -> pass
      - `bash scripts/ci/validate-doc-command-paths.sh` -> pass
      - `bash scripts/benchmark.sh --mode=fast` -> pass

## 6. References

- `scripts/codex/app_server_wrapper.py:198`
- `hooks/run-hook-codex.sh:20`
- `hooks/log.sh:109`
- `scripts/setup/install.sh:111`
- `scripts/setup/targets/codex-home.sh:44`
- `scripts/lib/settings_json.py:210`
- `schemas/install-modules.json:248`
- `schemas/vibeguard-project.schema.json:7`
- `scripts/verify/doc-freshness-check.sh:22`
- `.github/workflows/ci.yml:66`
- `tests/run_precision.sh:467`
- `eval/run_eval.py:36`
- `README.md:156`
