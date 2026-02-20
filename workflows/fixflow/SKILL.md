---
name: fixflow
description: "Execute coding tasks with a strict delivery workflow: build a full plan, implement one step at a time, run tests continuously, and commit by default after each step (`per_step`). Support explicit commit policy overrides (`final_only`, `milestone`) and optional BDD (Given/When/Then) when users ask for behavior-driven delivery or requirements are unclear."
---

# Fixflow

## Overview

Use this skill to deliver end-to-end engineering work in one run:
- Plan fully.
- Execute in strict sequence.
- Validate continuously.
- Use explicit commit policy (`per_step` default; `final_only`/`milestone` when requested).
- Add BDD behavior specs when requested or when requirements are ambiguous.

## Trigger Cues

Trigger this skill when the user asks for one or more of:
- Full plan + sequential execution.
- No backward compatibility.
- Test everything before handoff.
- Commit after completion or commit before each next step.
- Behavior-driven delivery (BDD) or acceptance scenarios.

## Workflow

### 1. Define Ready Criteria (DoR)

- Restate scope, constraints, and expected outputs.
- Record backward-compatibility mode: `required` or `not required`.
- Record validation scope:
  - Step-level checks.
  - Final full checks.
- Record commit policy: `final_only` / `per_step` / `milestone`.
- Commit policy mapping:
  - If user asks grouped commits by stage, use `milestone`.
  - If user asks a single final commit only, use `final_only`.
  - Otherwise default to `per_step` (each step: modify -> test -> commit).
- Record commit requirement and expected message style.
- Record dirty-worktree baseline (what existed before this run).
- Record blockers (permissions, missing env vars, unavailable services).

### 2. Build Complete Plan Before Editing

- Build a numbered plan covering all required changes.
- Order by risk/dependency:
  - Correctness/data integrity.
  - Security.
  - API/contract alignment.
  - UX/docs/cleanup.
- Define done condition for each step.
- Keep only one `in_progress` step at any time.

### 3. Add BDD Layer When Needed

Use BDD if user requests it, or if requirements are unclear.

#### 3.0 TDD Mode (RED → GREEN → IMPROVE)

When user requests TDD or test-driven delivery:

1. **RED** — Write a failing test first
   - Extract testable behavior from requirements
   - Write minimal test case asserting expected behavior
   - Run test, confirm it fails (red)
   - If test passes unexpectedly → requirement already met or test is wrong

2. **GREEN** — Write minimal implementation
   - Write just enough code to make the test pass
   - No extra improvements, no "while I'm here" changes
   - Run test, confirm it passes (green)

3. **IMPROVE** — Refactor under green tests
   - Eliminate duplication, improve naming, simplify logic
   - Run tests after each refactor to confirm no regression
   - Refactoring must not change external behavior

Coverage target: 80% line coverage for new code, 100% for critical paths.

Trigger cues for TDD mode:
- User says "TDD", "test-driven", "test first"
- User says "write tests before code"
- Requirements are well-defined with clear inputs/outputs

For BDD Lite, Scenario Quality Checklist, Scenario Outline, and Test Layer mapping, see the shared reference:

> [`workflows/references/bdd-guide.md`](../references/bdd-guide.md)


### 4. Execute Step by Step

- Implement one step fully before moving to the next.
- Include code, related config/docs, and immediate verification in the same step.
- For `per_step` (default):
  - Stage only files for current step.
  - Run step-level checks.
  - Commit immediately after step checks pass.
  - Record step -> commit hash mapping.
- For `final_only`:
  - Still run step-level checks before moving on.
  - Delay commit until final validation completes.
- For `milestone`:
  - Run step-level checks for each step.
  - Commit at defined milestone boundaries.
- Update plan status after each completed step.
- Continue automatically until all steps are done.

### 5. Apply No-Backward-Compatibility Mode (When Requested)

- Remove old paths, shims, adapters, and dual contracts.
- Prefer one clear implementation path.
- Treat breaking changes as intentional scope, not regressions.
- Document breaking impact in final report.

### 6. Validate with Test Matrix (Verification Loop)

Run checks per step and again at the end. Use continuous verification — never assume a change is correct without evidence.

Verification loop (per step):
1. Run relevant checks immediately after code change.
2. If any check fails → fix root cause → rerun ALL affected checks.
3. Only proceed to next step when ALL checks pass.
4. Maximum 3 fix attempts per check failure. If still failing after 3 attempts, stop and report.

Minimum matrix:
- Core logic: unit tests.
- Cross-module behavior: integration tests.
- Build health: compile/typecheck/build.
- Contract safety: API/serialization checks.
- Regression smoke: key user flow.

Failure loop:
1. Capture exact failing command/output.
2. Fix root cause.
3. Rerun failed check.
4. Rerun dependent checks.
5. Continue only when green.

### 7. Commit and Handoff

- Stage only relevant files from this run.
- Use a clear, scope-aligned commit message format.
- Commit behavior by policy:
  - `per_step` (default): each step must be tested and committed before next step starts.
  - `final_only`: single commit after final validation passes.
  - `milestone`: commit at each planned milestone boundary.
- Report:
  - Change summary.
  - Validation commands + outcomes.
  - Breaking changes (if any).
  - Commit list (ordered).
  - Any remaining pre-existing dirty files (if not part of current scope).

## Output Templates

### Plan Template

```text
Goal:
Constraints:
- Backward compatibility: <required|not required>
- Commit policy: <final_only|per_step|milestone>
- Validation scope: <...>
- Dirty baseline: <pre-existing files>

Steps:
1. <step> (done condition: <...>)
2. <step> (done condition: <...>)
...
```

### Final Report Template

```text
Completed:
- <item>

Validation:
- <command>: <pass/fail + key result>

Breaking Changes:
- <none | list>

Commits:
- <hash> <message> (step/milestone/final)
```

## Guardrails

- Do not stop at planning when implementation is expected.
- Do not leave partially completed plan steps.
- Do not defer required testing when it can be run now.
- Do not default to `final_only`; use `per_step` unless user explicitly asks otherwise.
- Do not move to the next plan step before committing when `commit_policy = per_step`.
- Do not claim compatibility if user explicitly requested no compatibility work.
- Do not include unrelated pre-existing dirty files in commits.
- Do not hand off without concrete validation evidence.
