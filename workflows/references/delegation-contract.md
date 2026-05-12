# Delegation Contract

Canonical delegation contract for VibeGuard multi-agent work. Use this document whenever work is split across child agents, background sessions, worktrees, or specialist prompts.

This contract extends the routing handoff in [`routing-contract.md`](routing-contract.md). The routing handoff decides whether delegation is allowed; this document defines how delegated work is assigned, executed, verified, and reintegrated.

## Roles

| Role | Responsibility |
|------|----------------|
| `leader` | Owns scope, task slicing, `lane_map`, stop conditions, and final user handoff. |
| `worker` | Owns only the assigned task slice and allowed files. Reports evidence and blockers. |
| `verification_owner` | Owns the required checks and decides whether evidence is sufficient. |
| `integration_owner` | Single writer for shared outputs, conflict resolution, final diff shaping, and merge readiness. |

The same person or agent may hold multiple roles, but each delegated lane must name exactly one owner. Parallel work without a single `integration_owner` is not allowed.

## Child-Agent Assignment Template

Every delegated task must receive this assignment before work starts:

```yaml
delegation_assignment:
  task_slice: <specific bounded outcome>
  allowed_files:
    - <files or directories this worker may modify>
  forbidden_files:
    - <files or directories this worker must not modify>
  read_only_files:
    - <files or directories this worker may inspect but not modify>
  authority: readonly | propose_patch | write_owned_files | verify_only
  required_evidence:
    - <commands, diffs, logs, or findings required for completion>
  blocker_conditions:
    - <conditions that require stopping and escalating>
  integration_owner: <single owner who merges shared outputs>
  verification_owner: <owner who runs or accepts checks>
  handoff_artifacts:
    - <paths or summaries the worker must return>
```

Field rules:

- `task_slice` must be narrow enough to finish without redefining the goal.
- `allowed_files` is the only writable set for `write_owned_files`.
- `forbidden_files` must include high-context files unless the task explicitly owns them.
- `read_only_files` may overlap across workers; writable files must not.
- `authority` must not exceed the task slice. Use `readonly` for discovery, `propose_patch` for suggested diffs, `write_owned_files` for exclusive owned files, and `verify_only` for checks.
- `required_evidence` must be concrete enough for the `integration_owner` to audit without redoing the work.
- `blocker_conditions` must include missing ownership, conflicting scope, and unexpected shared-file edits.

## Team Execution Pipeline

Use the staged pipeline below when work may outgrow a single direct execution lane:

| Stage | Entry condition | Owner | Output |
|-------|-----------------|-------|--------|
| `solo` | Task is bounded and no delegation is needed. | leader | Direct implementation and verification evidence. |
| `delegate_readonly` | More context is useful, but write ownership is not yet clear. | leader | Read-only findings, candidate file boundaries, and blockers. |
| `team_plan` | Multiple lanes are useful and scope is clear. | leader | `lane_map`, assignment templates, stop conditions, and integration owner. |
| `team_exec` | Assignments have disjoint writable files or isolated worktrees. | workers | Owned changes or patch proposals plus required evidence. |
| `team_verify` | Worker outputs are ready for integration. | verification_owner | Check results, review notes, and unresolved blockers. |
| `fix_loop` | Verification or review finds actionable issues. | integration_owner | Focused fixes, rerun checks, and updated evidence. |

Do not skip directly from `delegate_readonly` to `team_exec`. Write lanes require a `team_plan` assignment first.

## Parallelism Rules

Parallelize only when at least one of these is true:

- Work is read-only exploration.
- Writable files are disjoint and listed in `allowed_files`.
- Each worker uses an isolated worktree and the `integration_owner` performs the final merge.
- Verification can run independently from implementation without mutating shared files.

Serialize when any of these are true:

- Two workers need the same writable file.
- The work touches high-context files such as `AGENTS.md`, `CLAUDE.md`, `.claude/settings*.json`, hooks, setup scripts, or rule manifests.
- Generated artifacts and their source files must be updated together.
- A security-sensitive area is involved: auth, secrets, payments, shell execution, eval, or permissions.
- The owner of a lane, verifier, or integration step is missing or contradictory.

Safe write-lane limits:

- Default: one write lane.
- Up to two write lanes are allowed only when writable file sets are disjoint and explicit.
- More than two write lanes require isolated worktrees or a durable plan artifact that names every lane and its owner.
- Shared outputs must be written to temporary artifacts first, then merged by the `integration_owner`.

## Reintegration Protocol

Workers must return:

- changed paths or proposed patch paths
- commands run and outcomes
- unresolved blockers
- any deviation from the assignment

The `integration_owner` must:

- inspect worker outputs before merging
- resolve conflicts in one place
- update generated artifacts with their sources
- rerun the checks owned by `verification_owner`
- keep the final diff within the original scope

If a worker edited outside `allowed_files`, stop integration and treat the output as untrusted until reviewed.

## Blocker Escalation

Escalate back to `clarify_first` or a planning workflow when:

- the goal or non-goals are unclear
- ownership cannot be made disjoint
- a required tool, runtime, or rule snapshot is unavailable
- verification requires credentials or services the current session cannot access
- review finds a security-sensitive issue outside the assignment

Escalation must include the blocked lane, exact blocker, affected files, and the smallest decision needed to continue.
