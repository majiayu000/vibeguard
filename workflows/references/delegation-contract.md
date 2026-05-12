# Delegation Contract

Canonical contract for assigning, running, and reintegrating delegated agent work in VibeGuard. Use this document with [`routing-contract.md`](routing-contract.md): routing decides whether delegation is allowed, and this contract defines how delegated lanes must be shaped before work starts.

This contract implements W-14 parallel-agent ownership and complements W-20 runtime pinning for long tasks.

## When Delegation Is Allowed

Delegation is allowed only when all of these are true:

- The canonical router resolved to `execute_direct`, or a planning workflow emitted an execution handoff.
- `lane_map` assigns one owner to every delegated lane.
- Each write lane has an explicit child-agent assignment block.
- Writable file ownership is disjoint across lanes.
- One integration owner is named before any parallel work starts.
- Verification ownership is named in the handoff and reflected in the final verification loop.

If any condition is missing, return to `clarify_first` or serialize the work under the main executor.

## Child-Agent Assignment Template

Every delegated lane must be assigned with this template:

```yaml
delegation_assignment:
  task_slice: <bounded objective for this lane>
  allowed_files:
    - <paths or globs the lane may read/write>
  forbidden_files:
    - <paths or globs the lane must not modify>
  authority: readonly | propose_patch | write_patch | verify_only
  required_evidence:
    - <commands, logs, screenshots, or diff evidence required from the lane>
  blocker_conditions:
    - <conditions that stop this lane and escalate to the leader>
  integration_owner: <single owner who merges or rejects this lane's output>
```

Field rules:

- `task_slice` must be narrow enough that a worker can finish without redefining scope.
- `allowed_files` must be exact for write lanes. Broad globs are acceptable only for `readonly` exploration.
- `forbidden_files` must include files owned by adjacent write lanes and high-context files outside the lane.
- `authority` limits what the worker may do:
  - `readonly`: inspect and report only.
  - `propose_patch`: produce a patch or recommendation, but do not apply it.
  - `write_patch`: edit only `allowed_files`.
  - `verify_only`: run checks and report evidence only.
- `required_evidence` must include enough proof for the integration owner to accept or reject the lane.
- `blocker_conditions` must halt the worker before it guesses about scope, ownership, or failing checks.
- `integration_owner` must be a single named role or person, not a shared group.

## Leader Responsibilities

The leader owns orchestration, not every local detail:

- Choose `solo`, `delegate-readonly`, `team-plan`, `team-exec`, `team-verify`, or `fix-loop` stage.
- Emit or consume the routing handoff from [`routing-contract.md`](routing-contract.md).
- Build `lane_map` and one assignment block per delegated lane.
- Confirm writable lanes have disjoint `allowed_files`.
- Set the integration owner and verification owner before execution starts.
- Stop or serialize work when ownership overlaps.
- Integrate results, resolve conflicts, and produce the final verification record.

The leader must not treat worker output as merged merely because a worker completed.

## Worker Responsibilities

Workers own the assigned slice only:

- Stay inside `task_slice`, `allowed_files`, and `authority`.
- Do not edit `forbidden_files`.
- Do not redefine scope, public contracts, or verification ownership.
- Report blockers using the assigned `blocker_conditions`.
- Return the required evidence before marking the lane complete.
- Mention any files read or modified so the integration owner can audit the lane.

If the worker discovers a needed edit outside `allowed_files`, it must stop and escalate instead of expanding scope locally.

## Blocker Escalation

Escalate to the leader when any of these occur:

- The lane needs to touch a forbidden or ownerless file.
- Two lanes need the same writable file.
- A failing check requires changes outside the lane.
- The worker finds a schema, API, migration, security, or high-context instruction change.
- Required context is missing or contradicts the handoff.
- The same lane fails the same check three times.

Escalation output must include:

- blocker summary
- affected files
- evidence gathered
- proposed next routing: `serialize`, `revise_lane_map`, `clarify_first`, or `defer`

## Reintegration Ownership

Parallel work must converge through one integration owner:

- The integration owner reviews every lane's diff or report.
- The integration owner resolves conflicts and performs the final merge/synthesis.
- Workers do not merge adjacent lanes into shared files unless their assignment explicitly grants ownership of those files.
- Final verification must run after reintegration, even when each lane passed local checks.
- The final handoff must name accepted lanes, rejected lanes, rerun checks, and unresolved risks.

When reintegration changes behavior beyond a worker's output, it becomes a new execution step and must be verified as such.

## Staged Team Pipeline

Use this pipeline for multi-agent work:

1. `solo`
   - One executor owns discovery and edits.
   - Default for small, local, or unclear work.

2. `delegate-readonly`
   - Child agents may inspect independent areas and report findings.
   - No delegated writes are allowed.
   - Use this when the leader needs faster evidence without introducing merge risk.

3. `team-plan`
   - The leader creates `lane_map`, assignment blocks, stop conditions, and verification ownership.
   - Write lanes are not started until file ownership is explicit.

4. `team-exec`
   - Workers execute only their assigned slices.
   - The leader monitors blockers and serializes overlapping work.

5. `team-verify`
   - Verification lanes run assigned checks.
   - The integration owner reruns final checks after merge/synthesis.

6. `fix-loop`
   - Failed checks route back to the smallest responsible lane.
   - If ownership is ambiguous, serialize under the integration owner.
   - After three failed attempts on the same lane, stop and challenge the plan.

## Parallelism Decision Table

| Situation | Decision | Reason |
| --- | --- | --- |
| Independent read-only exploration | Parallelize | No writable state is shared. |
| Disjoint file ownership with explicit assignments | Parallelize | W-14 ownership is satisfied. |
| Independent test or verification commands | Parallelize | Results can be merged by evidence. |
| Same writable file needed by multiple lanes | Serialize | The merge point is shared state. |
| Schema, API, migration, or lockfile changes | Serialize | Downstream lanes depend on one contract. |
| Generated files or broad formatting changes | Serialize | Outputs commonly touch many owners. |
| Security-sensitive or high-context instruction files | Serialize unless explicitly owned | Incorrect merges can change agent authority or safety posture. |

Default maximum concurrent write lanes: `3`. Higher concurrency requires explicit worktree isolation, exact `allowed_files`, and a named integration owner for each branch of work.

## Worktree and File Ownership Isolation

- Use a separate worktree when the main checkout has unrelated user edits or when multiple write lanes would otherwise share a checkout.
- Each write lane must own a disjoint file set before edits begin.
- Shared generated outputs, lockfiles, migrations, schemas, and release metadata belong to the integration owner unless a lane assignment says otherwise.
- Read-only lanes may inspect broad paths but must not produce edits.
- The integration owner must inspect `git diff --name-only` before accepting each lane.

## Handoff Integration

Planning handoffs should keep the existing required keys from [`routing-contract.md`](routing-contract.md). The `lane_map` entry for each delegated lane points to an assignment block shaped by this contract.

Example:

```yaml
handoff:
  mode: fixflow
  artifacts:
    - plan/delegated-fix.md
  runtime_pinning_snapshot: .vibeguard/runtime-pinning.snapshot
  verification_owner: integration-owner
  stop_conditions:
    - any lane needs a forbidden file
  lane_map:
    docs: doc-worker
    tests: test-worker

delegation_assignments:
  docs:
    task_slice: update workflow docs to reference the new contract
    allowed_files:
      - README.md
      - docs/README_CN.md
      - workflows/**/*.md
    forbidden_files:
      - tests/**
      - scripts/**
    authority: write_patch
    required_evidence:
      - git diff --name-only
      - bash scripts/ci/validate-doc-paths.sh
    blocker_conditions:
      - documentation change requires a schema or generated file update
    integration_owner: integration-owner
```
