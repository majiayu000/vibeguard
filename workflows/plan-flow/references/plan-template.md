# Plan Template (Step-Test-Update Loop)

Use this template when creating `plan/<name>.md`.

```md
# <Task Name> execution plan

- Planned version: v1
- Applicable warehouse: <absolute path>
- Execution mode: Change each step -> Test now -> Write back plan -> Next step

## 0. Execution constraints (DoR)

- Objective: <clear objective>
- Compatibility: <required | not required>
- Submission strategy: <per_step | milestone | final_only>
- Test strategy:
  - Step level: at least 1 directed test + 1 health check per step
  - Final: operational phase/full return

## 1. Analysis results (before changes)

- Architecture inventory summary:
  - Model/configuration entry: <paths>
  - Factory/registry entry: <paths>
  - Adaptation layer entry: <paths>
  - Infrastructure entry (http/cache/storage/logging): <paths>
- Duplicate/redundant candidate list:

| id | category | documents and symbols | evidence | impact | risk | suggested direction of convergence |
|----|------|------------|------|------|------|--------------|
| F1 | <same-concept multi-def> | <path::symbol> | <call path/test/warn> | <high/med/low> | <high/med/low> | <canonical> |
| F2 | ... | ... | ... | ... | ... | ... |

## 2. Detailed steps (from analysis mapping)

### Step A1 <title>

- Status: `in_progress`
- Target: <what this step delivers>
- Expected changes to files:
  - `<file1>`
  - `<file2>`
- Detailed changes:
  - <implementation detail 1>
  - <implementation detail 2>
- Step-level test commands:
  - `<command 1>`
  - `<command 2>`
- Completion judgment:
  - <done criteria>

### Step A2 <title>

- Status: `pending`
- ...

## 3. Regression test matrix

- Phase completion check:
  - `<command>`
- Final inspection:
  - `<command>`

## 4. Execution log (appended after each step is completed)

- <YYYY-MM-DD>
  - Step A1: `completed`
    - Modify files:
      - `<file>`
    -Main changes:
      - <summary>
    - Execute tests:
      - `<command>` -> pass/fail
      - `<command>` -> pass/fail
```

## Status Transition Rules

- Only one step can be `in_progress`.
- Move to next step only after current step tests pass.
- If blocked, mark `blocked` with reason and evidence.

## Evidence Rules

- Keep exact command strings.
- Record pass/fail explicitly.
- If command cannot run, write the reason and closest fallback validation.
