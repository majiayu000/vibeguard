# ExecPlan Integration Instructions

> How ExecPlan works with VibeGuard’s existing plan-flow and plan-mode.

## When to use ExecPlan vs plan-flow vs plan-mode

| Tools | Applicable scenarios | Life cycle | Output |
|------|----------|----------|------|
| **plan-mode** | Single session task, user approval of the plan is required | Current session | Implementation plan (in-session consumption) |
| **plan-flow** | Stock code organization, redundancy analysis + gradual convergence | 1-3 sessions | plan/*.md (analysis + steps + logs) |
| **ExecPlan** | Long-term feature development, cross-session execution driven from SPEC | 2+ sessions | *-execplan.md (self-contained recovery document) |

### Decision tree

```
Mission accomplished
├── Can it be completed in one session?
│ ├── Yes → 1-2 file directly / 3-5 file plan-mode
│ └── No ↓
├──Is it the stock code organization/refactoring?
│ ├── Yes → plan-flow (redundant scan + gradual convergence)
│ └── No ↓
└──Is it new feature development/long-term task?
    └── yes → interview → SPEC → exec-plan → preflight → execution
```

## How plan-flow identifies ExecPlan

When plan-flow's redundancy_scan.sh scans, redundancy analysis should be skipped when encountering `*-execplan.md` files. Reason: ExecPlan's Concrete Steps have the same format as plan-flow's Step but have different semantics - ExecPlan steps describe what is to be done in the future, not redundant convergence records that have been completed.

Identification rules:
- Filename matches `*-execplan.md`
- or the file header contains `status: draft | active | completed | abandoned`

## Complete pipeline

```
/vibeguard:interview
    │
    ▼
  SPEC.md (Requirements Contract)
    │
    ▼
/vibeguard:exec-plan init
    │
    ▼
  *-execplan.md (execution plan)
    │
    ▼
/vibeguard:preflight (constraint set)
    │
    ▼
  Execution (progress step by step according to Concrete Steps)
    │
    ├── Complete each step → /vibeguard:exec-plan update
    ├── New session recovery → /vibeguard:exec-plan status
    └── Verification → /vibeguard:check
    │
    ▼
  Completed → /vibeguard:exec-plan update (mark completed)
```

## Relationship with preflight

ExecPlan and preflight are complementary:

- **ExecPlan** defines "what to do" - milestones, steps, verification criteria
- **preflight** defines "what not to do" - constraint sets, guard baselines, guard boundaries

Recommended process: First generate ExecPlan (clear execution path), then run preflight (establish protection boundary), and then perform self-check against preflight constraint set when executing ExecPlan steps.

## Cross-session recovery protocol

When execution resumes with a new session:

1. Read `*-execplan.md`
2. Run `/vibeguard:exec-plan status` to view the progress
3. Find the first `in_progress` or `pending` step
4. Read the Context chapter to restore the project context
5. Read the Decision Log to understand the existing decisions
6. Continue execution
