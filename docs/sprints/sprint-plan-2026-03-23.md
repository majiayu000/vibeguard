# Sprint Plan — 2026-03-23

Issues analyzed: #18–#31 (vibeguard repo)

## Dependency Analysis

### File-level conflicts identified

| File | Issues that touch it |
|------|----------------------|
| `hooks/log.sh` | #19, #22 |
| `hooks/post-build-check.sh` | #18, #23 |
| `hooks/run-hook.sh` | #25, #23, #31 |
| `hooks/pre-write-guard.sh` | #20, #27 |
| `hooks/pre-edit-guard.sh` | #20, #27 |
| Guard scripts (*.sh) | #20, #21, #28, #29 |
| `package.json` + CI | #24 |
| `docs/reference/` | #26 |

### Logical dependencies

- #18 needs project-scoped session ID from #19 to filter correctly
- #22 (rule graduation precision tracking) needs #19 for per-project session isolation
- #23 (circuit breaker) touches same files as #18 and #25 — root cause fix first
- #21 (ast-grep) is the prerequisite fix for most FPs in #28
- #20 (message format) affects all guard scripts — do before #27, #29, #30
- #29 (suppression comments) touches all guard scripts — do last after #20 and #21
- #31 (updatedInput) builds on hook infrastructure from #23 and #25

## Sprint Plan

SPRINT_PLAN_START
{
  "tasks": [
    {"issue": 19, "depends_on": []},
    {"issue": 20, "depends_on": []},
    {"issue": 21, "depends_on": []},
    {"issue": 24, "depends_on": []},
    {"issue": 25, "depends_on": []},
    {"issue": 26, "depends_on": []},
    {"issue": 18, "depends_on": [19]},
    {"issue": 22, "depends_on": [19]},
    {"issue": 27, "depends_on": [20]},
    {"issue": 28, "depends_on": [21]},
    {"issue": 23, "depends_on": [18, 25]},
    {"issue": 29, "depends_on": [20, 21]},
    {"issue": 30, "depends_on": [20, 25]},
    {"issue": 31, "depends_on": [23, 25]}
  ],
  "skip": []
}
SPRINT_PLAN_END

## Issue-by-issue rationale

| Issue | Priority | Depends on | Reason |
|-------|----------|------------|--------|
| #19 | P0 | — | Foundational: project-scoped session ID; #18 and #22 both read from `log.sh` |
| #20 | P0 | — | Guard message format v2; broad impact on all guard scripts, sets baseline for #27 #29 #30 |
| #21 | P1 | — | ast-grep migration; prerequisite for #28 FP fixes |
| #24 | P1 | — | npm publish verification; touches only `package.json` + CI, fully independent |
| #25 | P2 | — | Cross-platform shell: `.gitattributes` + env vars in `run-hook.sh`; must land before #23 and #31 touch the same file |
| #26 | P2 | — | Documentation only; no code conflict |
| #18 | P0 | #19 | `post-build-check.sh` session filter needs project-scoped session from #19 |
| #22 | P1 | #19 | Rule graduation system reads `log.sh`; shares session ID logic with #19 |
| #27 | P2 | #20 | Test-infra protection messages should use v2 format from #20 |
| #28 | P2 | #21 | Most false positives fixed by ast-grep migration in #21 |
| #23 | P1 | #18, #25 | Circuit breaker touches `post-build-check.sh` (#18 root cause first) and `run-hook.sh` (#25 cross-platform first) |
| #29 | P3 | #20, #21 | Suppression comments touch every guard script; #20 and #21 must settle the final format first |
| #30 | P3 | #20, #25 | Baseline scanning touches hook scripts; #20 settles message format, #25 settles shell portability |
| #31 | P3 | #23, #25 | updatedInput transparent correction builds on circuit-breaker hook infrastructure (#23) and cross-platform shell (#25) |
