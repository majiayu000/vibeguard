# ExecPlan Integration Instructions

> How ExecPlan works with VibeGuard’s existing plan-flow and plan-mode.

## Canonical Routing

ExecPlan follows the same precedence ladder as the rest of the workflow system. See [`workflows/references/routing-contract.md`](../../references/routing-contract.md).

Apply routing in this order:

1. `user_override`
2. `risk/destructive gate`
3. `ambiguity gate`
4. `readiness classifier`
5. `execution/delegation lane`

Readiness still resolves to exactly one of:

- `execute_direct`
- `plan_first`
- `clarify_first`

ExecPlan is a `plan_first` planner for long-running work. It should not be selected to compensate for ambiguity.

## When to use ExecPlan vs plan-flow vs plan-mode

| Tool | Applicable scenario | Lifecycle | Output |
|------|---------------------|-----------|--------|
| **plan-mode** | One-session planning after the route resolves to `plan_first` | Current session | Implementation plan for immediate follow-through |
| **plan-flow** | Convergence/refactor planning that needs durable `plan/*.md` evidence | 1-3 sessions | `plan/*.md` analysis + steps + logs |
| **ExecPlan** | Long-running feature or migration planning that needs cross-session recovery | 2+ sessions | `*-execplan.md` recovery document |

## How plan-flow identifies ExecPlan

When plan-flow's redundancy_scan.sh scans, redundancy analysis should be skipped when encountering `*-execplan.md` files. Reason: ExecPlan's Concrete Steps have the same format as plan-flow's Step but have different semantics - ExecPlan steps describe what is to be done in the future, not redundant convergence records that have been completed.

Identification rules:
- Filename matches `*-execplan.md`
- or the file header contains `status: draft | active | completed | abandoned`

## Complete pipeline

```
user_override / risk gate / ambiguity gate
    │
    ▼
readiness = plan_first
    │
    ▼
/vibeguard:interview (if a SPEC is still needed)
    │
    ▼
SPEC.md
    │
    ▼
/vibeguard:exec-plan init
    │
    ▼
*-execplan.md + W-20 runtime pinning snapshot + shared handoff
    │
    ▼
execution workflow consumes:
  mode / artifacts / runtime_pinning_snapshot / verification_owner / stop_conditions / lane_map
    │
    ├── step complete → /vibeguard:exec-plan update
    ├── new session → /vibeguard:exec-plan status
    └── verification → /vibeguard:check
    │
    ▼
completed → /vibeguard:exec-plan update
```

## Relationship with preflight

ExecPlan and preflight are complementary:

- **ExecPlan** defines "what to do" - milestones, steps, verification criteria
- **preflight** defines "what not to do" - constraint sets, guard baselines, guard boundaries

Recommended process: First generate ExecPlan (clear execution path), then run preflight (establish protection boundary), and then perform self-check against preflight constraint set when executing ExecPlan steps.

Before a long-running ExecPlan or interview handoff begins execution, capture W-20 pinning evidence:

```bash
bash guards/universal/check_runtime_drift.sh snapshot \
  --snapshot .vibeguard/runtime-pinning.snapshot \
  --tool-inventory .vibeguard/tool-inventory.txt
```

On cross-session resume, run the same guard in `check` mode before continuing execution. If it reports runtime, tool, or rule drift, stop until the user either rejects the drift or accepts it with a durable decision-log entry.

## Cross-session recovery protocol

When execution resumes with a new session:

1. Read `*-execplan.md`
2. Run `/vibeguard:exec-plan status` to view the progress
3. Find the first `in_progress` or `pending` step
4. Read the Context chapter to restore the project context
5. Read the Decision Log to understand the existing decisions
6. Reuse the last shared handoff fields:
   - `mode`
   - `artifacts`
   - `runtime_pinning_snapshot`
   - `verification_owner`
   - `stop_conditions`
   - `lane_map`
7. Run `check_runtime_drift.sh check` against `runtime_pinning_snapshot`
8. Continue execution only if the snapshot still matches or accepted drift has been recorded
