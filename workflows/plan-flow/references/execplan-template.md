# ExecPlan Template (long-term task execution plan)

> Source: OpenAI Harness Engineering ExecPlan specification, adapted to VibeGuard plan-flow format.
> ExecPlan is a living document - it can resume execution in a new session by itself, without additional context.

```md
# ExecPlan: <task name>

- Creation date: <YYYY-MM-DD>
- Source SPEC: <spec file path | None>
- Planned version: v1
- Status: draft | active | completed | abandoned

---

## 1. Purpose

What capabilities do users gain? One paragraph describing the final deliverables and core values.
Do not write any background information or reasons for technical selection (please put the reasons in the Decision Log).

## 2. Progress

> The only section that allows checklists. Each milestone corresponds to a set of steps in Concrete Steps.

- [ ] M1: <Milestone Description>
- [ ] M2: <Milestone Description>
- [ ] M3: <Milestone description>

## 3. Context

Minimal context required to resume execution:

- **Project Path**: <absolute path>
- **Language/Framework**: <e.g. Rust + Axum>
- **Key entry**: <e.g. src/main.rs, src/lib.rs>
- **Related Constraint Set**: <preflight output path | None>
- **Existing decision**: <reference Decision Log entry number>

## 4. Plan of Work

High-level work plan grouped by milestones, without implementation details (details in Concrete Steps).

### M1: <Milestone Name>
- Objective: <What to deliver>
- Involved files: <file list>
- Precondition: <Dependent milestone or external condition>

### M2: <Milestone Name>
- Target: ...
- Documents involved: ...
- Prerequisites: ...

## 5. Concrete Steps (specific steps)

> Format aligns to the Step format of plan-template.md. Each step must contain the exact command, working directory, and expected output.

### Step A1: <title>

- Status: `pending`
- Milestone: M1
- Goal: <What to deliver in this step>
- Expected changes to files:
  - `<file1>`
  - `<file2>`
- Detailed changes:
  - <Implementation details 1>
  - <Implementation details 2>
- Step-level test commands:
  - `<command>` — Expected: <pass/specific output>
- Completion judgment:
  - <done criteria>

### Step A2: <title>

- Status: `pending`
- Milestone: M1
- ...

## 6. Validation

Verification of observable behavior, specific to input/output:

| Scenario | Input | Expected Output | Verify Command |
|------|------|----------|----------|
| Normal path | <input> | <output> | `<command>` |
| Boundary cases | <input> | <output> | `<command>` |
| Error path | <input> | <output> | `<command>` |

Regression testing:
- `<Full test command>`

## 7. Idempotence

Safe retry paths and rollback procedures:

- **Safe to Retry**: <Describe why it is safe to retry the step>
- **Rollback procedure**: <git revert / manual steps>
- **Partially Completed Recovery**: <How to continue from an intermediate state>

## 8. Execution Journal

### Decision Log

| Date | Number | Decision | Reason | Alternatives |
|------|------|------|------|----------|
| <date> | D1 | <decision> | <reason> | <rejected plan> |

### Surprises

| Date | Number | Discovery | Impact | Processing |
|------|------|------|------|------|
| <date> | S1 | <description> | <Impact on plan> | <Adjustment measures> |

### Step Completion Log (step completion record)

- <YYYY-MM-DD>
  - Step A1: `completed`
    - Modify file: `<file>`
    -Main changes: <summary>
    - Test result: `<command>` -> pass
```

## Usage rules

1. **Progress is the only chapter that allows checklist** — other chapters are described in prose.
2. **Concrete Steps has only one `in_progress`** at a time - the next step can only be advanced after completing the current step test.
3. **Decision Log records all reasons for changes** — Deviations from the original SPEC must be recorded.
4. **ExecPlan is self-contained** — New sessions can resume execution with only the ExecPlan file and no reliance on chat history.
5. **Prose First** — Code blocks are used only for commands and output, and no nested fenced blocks are allowed.
