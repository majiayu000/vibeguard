# Sprint Signal Report: Issues #18-#31

Date: 2026-03-24
Repo: `majiayu000/vibeguard`
Scope: issue triage + file touchpoint diagnosis + dependency graph

## Signal Report

### #18 post-build-check consecutive fail counter missing session filter
- Status: open, not fixed
- Root cause: `hooks/post-build-check.sh` counts historical `warn` records without filtering `session`, causing cross-session accumulation.
- Primary files likely touched:
  - `hooks/post-build-check.sh`
  - `tests/test_hooks.sh`
  - `docs/known-issues/false-positives.md`

### #19 Session ID file should be project-scoped, not global
- Status: open, not fixed
- Root cause: `hooks/log.sh` persists session ID in `${VIBEGUARD_LOG_DIR}/.session_id` (global path), not project-scoped path.
- Primary files likely touched:
  - `hooks/log.sh`
  - `tests/test_hooks.sh`
  - `docs/how/learning-skill-generation.md`

### #20 Guard message format v2: OBSERVATION + SCOPE + DO NOT
- Status: open, not fixed
- Root cause: guard/hook messages are free-form and remediation-heavy; no applicability/scope boundaries for agent-safe consumption.
- Primary files likely touched:
  - `hooks/post-edit-guard.sh`
  - `hooks/post-write-guard.sh`
  - `hooks/pre-write-guard.sh`
  - `guards/typescript/check_any_abuse.sh`
  - `guards/typescript/check_console_residual.sh`
  - `guards/rust/check_unwrap_in_prod.sh`
  - `guards/go/check_error_handling.sh`
  - `tests/test_hooks.sh`

### #21 Migrate high-FP guards from grep to ast-grep
- Status: open, not fixed
- Root cause: grep/regex lacks AST structure and causes known false positives in TS/Rust/Go rules.
- Primary files likely touched:
  - `guards/typescript/check_any_abuse.sh`
  - `guards/typescript/check_console_residual.sh`
  - `guards/rust/check_unwrap_in_prod.sh`
  - `guards/go/check_error_handling.sh`
  - `hooks/pre-commit-guard.sh`
  - `tests/test_rust_guards.sh`
  - `tests/test_hooks.sh`
  - `sgconfig.yml` (new)

### #22 Rule graduation system: nursery -> warn -> error lifecycle
- Status: open, not fixed
- Root cause: no persisted precision/triage pipeline to promote/demote rules by measured quality.
- Primary files likely touched:
  - `hooks/log.sh`
  - `scripts/stats.sh`
  - `scripts/metrics_collector.sh`
  - `scripts/metrics-exporter.sh`
  - `scripts/` (new precision tracker artifacts)
  - `docs/known-issues/false-positives.md`

### #23 Hook circuit breaker: prevent infinite loops and repeated blocking
- Status: open, partially mitigated only (`hooks/stop-guard.sh` already avoids `exit 2`)
- Root cause: no shared circuit-breaker state machine for repeated block loops across hooks.
- Primary files likely touched:
  - `hooks/stop-guard.sh`
  - `hooks/pre-bash-guard.sh`
  - `hooks/log.sh`
  - `tests/test_hooks.sh`
  - `docs/reference/claude-code-known-issues.md`

### #25 Cross-platform shell: .gitattributes + PYTHONUTF8 + shell:bash
- Status: open, partially fixed (`.github/workflows/ci.yml` already uses `shell: bash`)
- Root cause: missing LF enforcement and Python UTF-8 env in runtime hook wrapper path.
- Primary files likely touched:
  - `.gitattributes` (new)
  - `hooks/run-hook.sh`
  - `.github/workflows/ci.yml`
  - `tests/test_hooks.sh`

### #27 Protect test infrastructure files from AI agent modification
- Status: open, not fixed
- Root cause: no guard-layer protected pattern enforcement for critical test infra files.
- Primary files likely touched:
  - `hooks/pre-edit-guard.sh`
  - `hooks/pre-write-guard.sh`
  - `hooks/pre-bash-guard.sh`
  - `tests/test_hooks.sh`

### #28 9 known false positives remain unfixed (P2 backlog)
- Status: open, not fixed
- Root cause: backlog umbrella covering unresolved FP clusters across Rust/Hook/doc-file checks; explicitly references #18 and #21-related items.
- Primary files likely touched:
  - `docs/known-issues/false-positives.md`
  - `hooks/post-build-check.sh`
  - `hooks/post-write-guard.sh`
  - `hooks/pre-bash-guard.sh`
  - `guards/rust/check_unwrap_in_prod.sh`
  - `guards/rust/check_nested_locks.sh`
  - `guards/rust/check_workspace_consistency.sh`
  - `guards/rust/check_single_source_of_truth.sh`
  - `guards/rust/check_taste_invariants.sh`
  - `tests/test_hooks.sh`
  - `tests/test_rust_guards.sh`

### #29 Suppression comments: // vibeguard-disable-next-line
- Status: open, not fixed
- Root cause: no per-line suppression parsing and no suppression telemetry.
- Primary files likely touched:
  - `guards/typescript/check_any_abuse.sh`
  - `guards/typescript/check_console_residual.sh`
  - `guards/rust/check_unwrap_in_prod.sh`
  - `guards/go/check_error_handling.sh`
  - `scripts/` (precision/suppression tracking integration)
  - `tests/test_hooks.sh`
  - `tests/test_rust_guards.sh`

### #30 Baseline scanning: only warn on new issues, not existing ones
- Status: open, partially fixed (staged-file filtering exists; baseline commit comparison not implemented)
- Root cause: missing baseline-aware diff policy for non-pre-commit scans and explicit baseline reference workflow.
- Primary files likely touched:
  - `hooks/pre-commit-guard.sh`
  - `guards/typescript/common.sh`
  - `guards/go/common.sh`
  - `guards/rust/common.sh`
  - `scripts/compliance_check.sh`
  - `tests/test_hooks.sh`

### #31 Claude Code updatedInput: transparent correction instead of block+retry
- Status: open, not fixed
- Root cause: PreToolUse hooks currently return block/warn; no `decision: allow` + `updatedInput` correction path.
- Primary files likely touched:
  - `hooks/pre-bash-guard.sh`
  - `hooks/pre-write-guard.sh`
  - `hooks/pre-edit-guard.sh`
  - `tests/test_hooks.sh`
  - `docs/reference/claude-code-known-issues.md`

## Dependency Graph

SPRINT_PLAN_START
{
  "tasks": [
    {"issue": 18, "depends_on": []},
    {"issue": 19, "depends_on": []},
    {"issue": 20, "depends_on": []},
    {"issue": 21, "depends_on": [20]},
    {"issue": 22, "depends_on": []},
    {"issue": 23, "depends_on": []},
    {"issue": 25, "depends_on": []},
    {"issue": 27, "depends_on": []},
    {"issue": 28, "depends_on": [18, 21]},
    {"issue": 29, "depends_on": [21, 22]},
    {"issue": 30, "depends_on": [21, 22]},
    {"issue": 31, "depends_on": [23]}
  ],
  "skip": []
}
SPRINT_PLAN_END
