# Sprint Plan — Guard Issues #19/#21/#27/#28/#29/#30/#31

Date: 2026-03-24
Source repo: `majiayu000/vibeguard`

## Signal Report (Diagnose Before Fix)

### #19 Session ID file should be project-scoped
- Root cause: `hooks/log.sh` stores session id in global path `${VIBEGUARD_LOG_DIR}/.session_id`, causing project crossover within renewal window.
- Primary files touched:
  - `hooks/log.sh`
  - `tests/test_hooks.sh` (regression coverage likely needed)

### #21 Migrate high-FP guards from grep to ast-grep
- Root cause: grep/regex checks lack AST context and generate structural false positives.
- Primary files touched:
  - `guards/typescript/check_any_abuse.sh`
  - `guards/typescript/check_console_residual.sh`
  - `guards/go/check_error_handling.sh`
  - `guards/rust/check_unwrap_in_prod.sh`
  - `guards/rust/check_declaration_execution_gap.sh`
  - likely new ast-grep rule/config files and related tests

### #27 Protect test infrastructure files from AI agent modification
- Root cause: `pre-edit-guard` currently validates path existence/old_string only; it does not protect test infra targets.
- Primary files touched:
  - `hooks/pre-edit-guard.sh`
  - `tests/test_hooks.sh`

### #28 9 known false positives remain unfixed
- Root cause: multiple documented FP classes remain in active scripts; issue is an umbrella spanning Rust guards and hook-level matchers.
- Primary files touched:
  - `guards/rust/check_unwrap_in_prod.sh`
  - `guards/rust/check_nested_locks.sh`
  - `guards/rust/check_workspace_consistency.sh`
  - `guards/rust/check_single_source_of_truth.sh`
  - `guards/rust/check_taste_invariants.sh`
  - `hooks/post-write-guard.sh`
  - `hooks/post-build-check.sh`
  - `hooks/pre-bash-guard.sh`
  - `docs/known-issues/false-positives.md`

### #29 Suppression comments (`vibeguard-disable-next-line`)
- Root cause: no line-scoped suppression protocol exists across guard scripts.
- Primary files touched:
  - `guards/rust/common.sh`, `guards/go/common.sh`, `guards/typescript/common.sh`
  - rule scripts in `guards/rust/*.sh`, `guards/go/*.sh`, `guards/typescript/*.sh`
  - `tests/*` for suppression behavior

### #30 Baseline scanning only warns on new issues
- Root cause: partial diff-only behavior exists, but end-to-end baseline/new-only capability is not consistently implemented for all scanning entrypoints.
- Primary files touched:
  - `hooks/pre-commit-guard.sh`
  - `hooks/post-edit-guard.sh`
  - `mcp-server/src/tools.ts` (for `/vibeguard:check` style baseline support)
  - `docs/command-schemas.md` and tests

### #31 Claude Code `updatedInput` transparent correction
- Root cause: pre-tool guards currently block/warn; they do not emit `updatedInput` corrections.
- Primary files touched:
  - `hooks/pre-bash-guard.sh` (mechanical command rewrites)
  - potentially `hooks/pre-edit-guard.sh` / `hooks/pre-write-guard.sh` for path normalization use-cases
  - `tests/test_hooks.sh`

## Dependency Graph

SPRINT_PLAN_START
{
  "tasks": [
    {"issue": 19, "depends_on": []},
    {"issue": 21, "depends_on": []},
    {"issue": 27, "depends_on": []},
    {"issue": 28, "depends_on": [21]},
    {"issue": 29, "depends_on": [21, 28]},
    {"issue": 30, "depends_on": [21]},
    {"issue": 31, "depends_on": [28]}
  ],
  "skip": []
}
SPRINT_PLAN_END

## Rationale Summary
- #21 is the structural guard-engine migration; #28 and #29 overlap those guard files and are sequenced after it.
- #31 and #28 both require edits in `hooks/pre-bash-guard.sh`, so #31 is sequenced after #28 to avoid merge churn.
- #19 and #27 are isolated and can start immediately.
- #30 is scheduled after #21 because baseline/new-only behavior must align with the migrated guard execution model.
