---
name: plan-flow
description: "Analyze repository-level duplicate/redundant design first, then build and execute a strict step-test-update plan in docs/plan. Use for deep architecture review, convergence planning, and traceable one-step-at-a-time delivery."
---

# Plan Flow

## Overview

Use this skill when the user needs:
- A complete analysis of duplicated/redundant design in a codebase.
- A detailed TODO plan with explicit file-level steps.
- Strict execution evidence: change one step, test it, then update plan status.

This skill is repository-agnostic. It defines how to analyze and plan, not only what was done in one specific repo.

## When to Activate

- The canonical router resolved the task to `plan_first`.
- The user needs a durable `plan/*.md` artifact with file-level steps and evidence.
- The work requires duplicate/redundant design analysis before edits.

## Red Flags

- A plan step lacks exact files, symbols, or verification commands.
- Execution starts from a `clarify_first` situation with unresolved boundaries.
- Multiple plan items are completed without updating status and evidence.

## Checklist

- [ ] Capture baseline branch, dirty state, constraints, and known blockers.
- [ ] Convert every finding into a scoped step with owner and validation.
- [ ] Keep exactly one plan item in progress and update it before moving on.

## Routing Contract Integration

Plan Flow owns the task only after the canonical router in [`workflows/references/routing-contract.md`](../references/routing-contract.md) resolves to `plan_first`.

Require the complete validated `routing_decision`, including its exact
`precedence`, a resolved `work_surface` of `code_execution`,
`writing_research`, or `chat_support`, and a `readiness` value of
`execute_direct`, `plan_first`, or `clarify_first`. Preserve that object unchanged beside
the execution handoff; do not nest it inside the handoff or reconstruct it
from planning artifacts. If a new user instruction changes the deliverable
surface, return to the canonical router before planning or execution continues.

Route into Plan Flow when these readiness signals are true:

- ambiguity has already been resolved
- execution should not start directly
- the task needs a durable `plan/*.md` artifact, phased sequencing, or explicit convergence evidence

Do not use Plan Flow to compensate for a `clarify_first` outcome. Missing non-goals, decision boundaries, or lane ownership must be clarified before planning starts.

When Plan Flow finishes planning, emit the shared execution handoff with these required keys:

- `mode`
- `artifacts`
- `runtime_pinning_snapshot`
- `verification_owner`
- `stop_conditions`
- `lane_map`

`artifacts` must include the generated `plan/*.md` path. `runtime_pinning_snapshot` must point at the W-20 snapshot for long tasks, or be `None` for short direct work. `lane_map` must name the owner for every delegated lane before execution starts.

When Plan Flow proposes child-agent or parallel execution, it must also emit delegation assignments that follow [`workflows/references/delegation-contract.md`](../references/delegation-contract.md). Missing assignment boundaries keep the route in `clarify_first`.

## Core Workflow (Analyze -> Plan -> Execute)

1. Establish scope and constraints.
- Confirm target directories/modules and out-of-scope areas.
- Capture compatibility requirement, risk tolerance, and testing expectations.
- Record baseline (`git status --short`, current branch, known blockers).

2. Run structured redundancy analysis first.
- Build an inventory of architecture anchors:
  - Domain models and schemas
  - Factory/registry entry points
  - HTTP/storage/cache/logging abstractions
  - Route/service/provider adapters
- Identify duplicate/redundant candidates with evidence:
  - Same concept, multiple conflicting definitions
  - Same responsibility, parallel implementations
  - Exported but unconnected modules
  - Dead/legacy paths still affecting readability
- For each finding, record:
  - Exact files and symbols
  - Call path or usage evidence
  - Risk if changed
- See `references/analysis-playbook.md`.

3. Prioritize and convert analysis into executable plan.
- Score each finding by impact/effort/risk/confidence.
- Group into phases (`P0`, `P1`, `P2`) and sequence low-risk/high-signal steps first.
- Create or update `plan/<task>.md` from `references/plan-template.md`.
- Keep exactly one step in `in_progress`.
- Use statuses: `pending` / `in_progress` / `completed` / `blocked`.
- See `references/risk-impact-scoring.md`.

4. Execute with strict step-test-update loop.
- Implement only the current step and only in listed files.
- Run step-level tests immediately, then project health checks.
- Update plan status and execution log before touching next step.
- On failure, record root cause and run fix loop before continuing.

5. Close with phase/final verification.
- Run phase matrix checks and final regression set.
- Report residual risks, deferred work, and explicit coverage gaps.

## Quality Gates

- No finding enters the plan without file-level evidence.
- No step is `completed` without test command evidence.
- No next step starts before plan status/log update is written.
- If full regression is unavailable, record exact reason and nearest fallback checks.

## Reference Map

- `references/analysis-playbook.md`
  - How to detect duplicate/redundant design with reproducible evidence.
- `references/risk-impact-scoring.md`
  - How to prioritize findings into phases and step order.
- `references/plan-template.md`
  - Reusable plan skeleton including analysis table, step template, and log format.
- `references/plan-accomplishments.md`
  - One completed real example (for style and granularity only, not as mandatory scope).

## Scripts

- `scripts/redundancy_scan.sh <target_dir>`
  - Fast first-pass scan for duplicate symbol names, parallel factory/builders, and legacy/dead-code hints.
- `scripts/findings_to_plan.py --target-dir src --output plan/<name>.md`
  - Convert scan findings into a draft execution plan with scoring and phased order (`P0/P1/P2`).
- `scripts/plan_lint.py <plan/file.md>`
  - Validate plan state machine, test evidence, and execution-log completeness for completed steps.

## When to Activate

Trigger this skill when user asks for:
- "Analyze what duplicate designs/redundant designs there are in this library"
- "Make a very complete and detailed todolist/execution plan"
- "Test and update plan status after every change"
- "Progress step by step and trackable"

## Execution Rules

- Prefer small, reversible steps over large refactors.
- Keep plan language specific to file paths, symbols, and commands.
- Avoid mixing analysis conclusions with unverified assumptions.
- If new evidence contradicts earlier assumptions, revise plan before coding.

## Red Flags

- **Plan before duplicate search** - planning without redundancy evidence can institutionalize duplicated design.
- **Vague tasks** - steps without file paths, symbols, or done conditions are not executable.
- **Unowned parallel work** - delegated tasks must have disjoint ownership before execution.
- **Assumptions treated as findings** - every finding needs evidence or an explicit uncertainty marker.

## Checklist

- [ ] Run or document the duplicate/redundancy search before drafting the plan.
- [ ] Convert findings into scored, phased execution steps.
- [ ] Include artifacts, runtime pinning, verification owner, stop conditions, and lane map.
- [ ] Validate the plan with `plan_lint.py` when a plan file is created.
- [ ] Update the plan when new evidence invalidates an earlier assumption.
