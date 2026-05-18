# Routing Contract

Canonical routing contract for VibeGuard workflow selection. All workflow prompts, public docs, and dispatcher guidance must reference this document instead of redefining routing rules locally.

Delegated execution is defined by [`delegation-contract.md`](delegation-contract.md). This routing contract decides whether delegation can start; the delegation contract defines assignments, parallelism, verification, and reintegration.

Executable schema sources:

- `schemas/workflow-routing-decision.schema.json`
- `schemas/workflow-execution-handoff.schema.json`
- `schemas/workflow-lane-map.schema.json`
- `schemas/workflow-verification-gate.schema.json`

## Precedence

Apply routing in this order:

1. `user_override`
2. `risk/destructive gate`
3. `ambiguity gate`
4. `readiness classifier`
5. `execution/delegation lane`

Later stages must not override an earlier decision without an explicit new user instruction.

## Decision Model

### 1. User Override

- If the user explicitly selects a workflow or says to plan first, treat that as the requested lane.
- User override does not bypass the risk/destructive gate or the ambiguity gate.

### 2. Risk / Destructive Gate

- Route to a safety-first lane before execution when the requested action is destructive, high-risk, or irreversible.
- Examples: force-push, schema/data deletion, production config mutation, broad automated rewrites.

### 3. Ambiguity Gate

Route to `clarify_first` when execution or planning would require guessing any of:

- the concrete goal
- explicit non-goals
- decision boundaries
- ownership for delegated work

Planning is not a substitute for missing task boundaries.

### 4. Readiness Classifier

The readiness classifier has exactly three outputs:

- `execute_direct`
- `plan_first`
- `clarify_first`

Choose `execute_direct` when the task is bounded, the next edits are clear, and verification can be owned immediately.

Choose `plan_first` when the task is well-specified but multi-step enough that execution needs an explicit artifact handoff before code changes begin.

Choose `clarify_first` when required scope or decision boundaries are missing.

File count may be used as a secondary hint, but it is not the contract and must not replace the readiness outputs above.

### 5. Execution / Delegation Lane

- `execute_direct` enters an execution workflow immediately.
- `plan_first` enters a planning workflow that emits the shared handoff block below.
- Delegation is allowed only when `lane_map` assigns a single owner to each lane and no lane is left ownerless.
- Delegated child-agent work must use the assignment template in [`delegation-contract.md`](delegation-contract.md) before any write lane starts.
- Long tasks that cross 3 or more agent steps, run for 10 minutes or longer, or enter `/vibeguard:interview` / `/vibeguard:exec-plan` must capture a W-20 runtime pinning snapshot before execution starts.

If delegation ownership is missing or conflicting, stop and return `clarify_first`.

## Shared Planning Handoff

Planning workflows must emit the same execution handoff payload:

```yaml
handoff:
  mode: <execution mode selected by the planner>
  artifacts:
    - <paths to the plan, spec, or other required artifacts>
  runtime_pinning_snapshot: <path to W-20 snapshot | None for short direct tasks>
  verification_owner: <who owns verification for this handoff>
  stop_conditions:
    - <conditions that must halt execution>
  lane_map:
    <lane_name>: <owner>
```

Required keys:

- `mode`
- `artifacts`
- `runtime_pinning_snapshot`
- `verification_owner`
- `stop_conditions`
- `lane_map`

Consumption rules:

- Execution workflows must honor all required keys.
- `mode` is preselected by planning; execution workflows do not re-route back to planning on their own.
- `artifacts` are the canonical inputs for downstream execution.
- `runtime_pinning_snapshot` records the pinned runtime, tool inventory, and VibeGuard rule hash for long tasks.
- `verification_owner` names who closes the verification loop.
- `stop_conditions` are hard boundaries, not suggestions.
- `lane_map` must show ownership for every delegated lane before parallel work starts, and every delegated lane must receive a matching delegation assignment.

## Workflow Ownership

- `plan-mode` owns one-session planning after the route resolves to `plan_first`.
- `plan-flow` owns traceable multi-step planning when a durable `plan/*.md` artifact is needed.
- `fixflow` and other execution workflows own direct execution after `execute_direct`, or after a planning handoff preselects them.
- `auto-optimize` only runs autonomously when readiness and delegation ownership are already explicit.
- `agents/dispatcher.md` chooses a specialist inside the already selected lane; it does not infer `plan` vs `execute`.
- `workflows/references/delegation-contract.md` owns child-agent assignment, team pipeline stages, parallelism limits, and reintegration rules.

## Examples

### Explicit User Override

User says: "Use plan mode first, then hand off execution."

- `user_override`: select planning lane
- if no ambiguity remains: readiness resolves to `plan_first`
- planner emits shared handoff block

### Ambiguous Request with Missing Non-Goals

User says: "Clean up the workflow system."

- ambiguity gate fails because non-goals and decision boundaries are missing
- output: `clarify_first`

### Destructive or High-Risk Task

User says: "Delete the legacy schema and push directly to production."

- risk/destructive gate triggers before readiness
- route to a safety-first planning/review lane

### Small, Clear Task

User says: "Update the README link that points to the wrong file."

- ambiguity gate passes
- readiness output: `execute_direct`

### Large, Well-Specified Task

User says: "Implement the approved routing contract across workflows and docs."

- ambiguity gate passes
- readiness output: `plan_first`
- planner emits shared handoff block before execution

### Delegation Without Lane Ownership

Planner proposes parallel execution but omits who owns doc verification.

- `lane_map` is incomplete
- output: `clarify_first` until ownership is explicit

### Delegation Without Assignment Boundaries

Planner names lane owners but does not provide allowed files, forbidden files, authority, evidence, blockers, or integration owner.

- delegation assignment is incomplete
- output: `clarify_first` until the missing assignment fields are explicit
