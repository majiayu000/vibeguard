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

If user says “I don't understand BDD”, explain first in simple terms:
- BDD means defining expected behavior before coding.
- Use `Given / When / Then`:
  - Given: starting context.
  - When: action/event.
  - Then: observable result.

#### 3.1 BDD Lite (default mode)

Use this lightweight sequence unless user asks for full formal BDD:
1. Extract 2-5 key behaviors from the request.
2. Write one `Scenario` per behavior.
3. Map each `Then` to at least one verification step.
4. Implement code.
5. Run mapped checks and confirm each `Then` is satisfied.

Create scenarios before implementation:

```gherkin
Feature: <capability>
  Scenario: <business behavior>
    Given <initial state>
    When <user/system action>
    Then <expected outcome>
```

#### 3.2 Scenario Quality Checklist

Each scenario should satisfy all:
- Single behavior focus (no mixed goals in one scenario).
- Observable `Then` (not implementation detail).
- Explicit preconditions in `Given`.
- Explicit trigger in `When`.
- At least one failure or edge scenario for risky behavior.

#### 3.3 Scenario Outline (for data-driven behavior)

Use `Scenario Outline` when same behavior repeats with different inputs:

```gherkin
Feature: Search filtering
  Scenario Outline: Filter by item type and tags
    Given the knowledge base has items of multiple types
    When I search with type "<type>" and tag "<tag>"
    Then I only get items matching "<type>" and "<tag>"

    Examples:
      | type      | tag      |
      | knowledge | rust     |
      | skill     | backend  |
```

#### 3.4 Map BDD to Test Layers

- Unit tests: validate pure logic behind `Then`.
- Integration tests: validate cross-module contract behaviors.
- API/contract tests: validate request/response and error semantics.
- E2E/smoke tests: validate user-visible critical scenarios.

Minimum rule: every high-priority scenario must be covered by at least one automated check.

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

### 6. Validate with Test Matrix

Run checks per step and again at the end.

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

### BDD Template

```gherkin
Feature: <feature name>
  Scenario: <main behavior>
    Given <context>
    When <action>
    Then <expected result>
```

Optional outline template:

```gherkin
Feature: <feature name>
  Scenario Outline: <repeated behavior>
    Given <context>
    When <action using "<input>">
    Then <expected "<output>">

    Examples:
      | input | output |
      | ...   | ...    |
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
