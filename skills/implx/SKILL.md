---
name: implx
description: "Use when the user says \"implx\", \"use implx\", \"用 implx\", or asks for the one-line SpecRail queue shortcut. Plain implx means drain the full actionable issue/PR queue in review mode: run SpecRail preflight, create missing spec/task PR work before implementation, use threads for reviewer/merge-reviewer lanes when available, create per-issue implementation PRs, require CI/reviewThreads/pr_gate evidence, preserve per-PR human merge authorization, and perform closure audit. Say \"implx auto\" / \"implx 自动\" for the explicit auto mode that treats the invocation as standing merge authorization for this run."
---

# Implx

Use this skill as a short operational entrypoint. It only recognizes the
`implx` shorthand, records the queue mode, performs the minimum startup checks,
and delegates execution policy to the focused SpecRail skills.

Do not duplicate the implementation-queue contract here. The authoritative
queue planning, spec coverage gate, context budget, runtime checkpoint, threads
orchestration, PR gate, and closure-audit rules live in
`skills/specrail-implement-queue/SKILL.md`.

## Startup

1. Run the normal SpecRail startup before remote writes:
   - read the repository `AGENTS.md`
   - read `AGENT_USAGE.md`, `workflow.yaml`, `states.yaml`, `labels.yaml`, and
     `skills/specrail-workflow/SKILL.md` when present
   - select the human-facing locale
   - identify human gates and route-gate requirements
2. Fetch current remote state before mapping a GitHub queue.
3. List open issues, open PRs, current branch, dirty files, and worktrees.
4. Map existing PRs before creating replacement PRs.
5. Record queue scope. Plain `implx`, `use implx`, or `用 implx` means full
   actionable queue drain unless the prompt explicitly narrows the scope.

## Queue Mode

Use `queue_mode: full_queue_drain` for the plain shorthand:

- `implx`
- `use implx`
- `用 implx`

These explicit forms are equivalent:

- `implx drain full queue`
- `implx resume full queue`
- `用 implx 完成所有 actionable issues 和 PRs`
- `用 implx 做完整队列`

Use `queue_mode: bounded_tranche` only when the prompt explicitly limits scope,
for example one issue, one PR, the current tranche, plan-only, status-only, or
review-only work.

## Authorization Mode

Two modes. Record the selected mode at startup and pass it downstream.
The repository's persisted `automation_policy.auth_mode` is a `review` safety
baseline; it never selects or authorizes auto mode.

`auth_mode: review` — the DEFAULT for plain `implx`, `use implx`, `用 implx`,
`implx review`, `implx 审核`, and `implx 人工`:

- Preserve per-PR explicit human merge authorization in the current
  conversation before any merge.
- Route `needs_spec` / `needs_tasks` to spec-writing skills but wait for
  human confirmation before implementing from a freshly drafted spec.

`auth_mode: auto` — selected only by a current user message that explicitly says
`implx auto` or `implx 自动`:

- The explicit `implx auto` invocation itself IS the standing merge
  authorization for this run. Do not ask per-PR "can I merge" questions.
- Merge a PR when ALL evidence is current and green per
  `skills/specrail-implement-queue/SKILL.md` (CI rollup, PR gate, resolved
  review threads, clean merge state, reviewer-lane evidence).
- Use closing keywords for final slices so merged PRs close their issues;
  close merged-but-open issues during closure audit.
- `needs_spec` / `needs_tasks` issues are actionable: auto-draft the spec or
  task packet via the focused SpecRail skills, then implement. Do not park
  them waiting for human spec approval.
- Items that genuinely need a human decision (duplicate-ownership conflicts,
  maintainer waivers, probe or time-window gates, destructive or irreversible
  actions, conflicting review feedback, architecture-level rewrites) never
  block the queue: skip them, keep draining, and report them once in a final
  `human_decisions` list with a recommended action each.

In both modes, never force-push, delete unmerged branches, replace a
maintainer-writable PR without cause, publish releases, or act outside the
repository without explicit instruction. Auto mode does not weaken the
Bounded Tranche Hard Stop, reviewer-lane, or self-review authorization rules.

`full_queue_drain` means the objective spans the whole actionable queue, not
that one session runs unbounded. Execution is a sequence of bounded tranches:
each session declares a hard budget (compaction count and/or item cap) in the
runtime checkpoint at tranche start, stops when the budget is exhausted, and
hands off to a fresh session via the checkpoint. See the Bounded Tranche Hard
Stop rules in `skills/specrail-implement-queue/SKILL.md`.

Pass the selected modes to `skills/specrail-implement-queue/SKILL.md`:

```yaml
implx_context:
  overall_objective:
  queue_mode: bounded_tranche | full_queue_drain
  auth_mode: auto | review
  user_authorization:
  current_branch:
  dirty_files:
  open_issues:
  open_prs:
```

## Delegate

After startup, load `skills/specrail-implement-queue/SKILL.md` for any issue or
PR queue. That skill owns:

- spec coverage classification
- implementation candidate selection
- one-issue-per-PR planning
- partial versus final closing semantics
- context-budget and runtime-checkpoint behavior
- optional threads orchestration
- verification, PR-gate evidence, and closure audit

For one small scoped issue, follow that skill's instruction to route to
`skills/specrail-implement/SKILL.md`.

## Threads

If the queue needs native parallel lanes, reviewer lanes, CI waits,
review-thread checks, merge gates, or closure audit, load
`skills/specrail-implement-queue/SKILL.md` and then follow the orchestration rules in
`skills/specrail-implement-queue/SKILL.md`.

For GitHub issue or PR queues, reviewer lanes, merge gates, and closure audit
make native thread dispatch required whenever native subagent capability is
available. Record `thread_dispatch_gate` before implementation, review, or
merge work. A coordinator self-review is not a native thread and does not
satisfy merge review.

If no native threads capability is available, continue with the single-agent
SpecRail flow only after recording the fallback and reporting that no native
threads were launched.

## Boundaries

- In `auto` mode, merge only on complete current evidence (CI, review threads,
  merge state, PR gate, reviewer lane); evidence gaps mean skip and report,
  not ask.
- In `review` mode, do not merge without explicit human authorization in the
  current conversation.
- Do not treat green CI as merge readiness without review-thread and merge-state
  truth.
- Do not close an issue from a partial implementation.
- Do not replace an existing maintainer-writable PR unless it is stale, unsafe,
  unwritable, or a human approves replacement.
- Do not use old Codex session logs as queue state.

## Handoff

Report the compact handoff produced by the focused queue skill. Include this
`implx` wrapper context when useful:

```yaml
implx_handoff:
  route: implement_queue
  overall_objective:
  queue_mode:
  auth_mode:
  delegated_skill: skills/specrail-implement-queue/SKILL.md
  queue_truth:
    open_issues:
    open_prs:
    current_branch:
    dirty_files:
  human_decisions:
  focused_handoff:
  thread_dispatch_gate:
    native_subagents:
    spawn_requirement:
    native_thread_evidence:
```

## When to Activate

- Activate this route only when the request matches the skill description and the SpecRail router selected it.
- Use it after loading repository instructions, workflow policy, and the current user-authorized scope.

## Red Flags

- Required issue, spec, PR, runtime, or review evidence is missing or stale.
- A proposed action would bypass an offline gate, CI, review, or human authorization.
- The route would ignore configured paths, duplicate an artifact, or cross the requested scope.

## Checklist

- [ ] Confirm the route, configured paths, locale, and authorization mode before writes.
- [ ] Search first and record missing evidence or human gates without inventing state.
- [ ] Run the focused validator and report its exact decision or blocker.
