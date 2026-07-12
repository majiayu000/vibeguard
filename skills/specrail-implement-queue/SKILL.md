---
name: specrail-implement-queue
description: Use when implementing or draining a GitHub issue/PR queue in a SpecRail-governed repository where approved specs already exist, such as multiple numbered docs/specs/GH packets that need one or more implementation PRs per issue. Maps issues to specs and existing PRs, supports full-queue drain requests from implx, selects single-agent or optional threads orchestration, preserves partial versus final closing semantics, and requires SpecRail verification plus PR gates before merge-readiness claims.
---

# SpecRail Implement Queue

Use this skill for approved-spec implementation queues. For one small issue,
route to `skills/specrail-implement/SKILL.md` instead.

## Startup

1. Run the SpecRail workflow startup:
   - read `AGENTS.md`, `AGENT_USAGE.md`, `workflow.yaml`, `states.yaml`,
     `labels.yaml`, and `skills/specrail-workflow/SKILL.md` when present
   - select the locale
   - identify the `implement` route and human gates
2. Fetch current remote state before mapping the queue.
3. List open issues, open PRs, local branch, dirty files, and worktrees.
4. For each candidate issue, read:
   - the GitHub issue
   - `docs/specs/GH<issue-number>/product.md`
   - `docs/specs/GH<issue-number>/tech.md`
   - `docs/specs/GH<issue-number>/tasks.md`
5. Map existing PRs before creating replacement PRs.
6. Collect duplicate-work evidence before opening an implementation lane:

```sh
python3 checks/github_duplicate_evidence.py --github-repo <owner/repo> --issue <issue-number> --json > duplicate-work-evidence.json
python3 checks/route_gate.py --repo . --route implement --issue <issue-number> --state ready_to_implement --duplicate-evidence duplicate-work-evidence.json --json
```

If duplicate evidence is missing, the implementation route needs human input.
If it shows an open PR for the issue, the route is blocked. If it shows only a
matching remote branch, an ownership decision is needed before creating a
competing branch or PR: in `auth_mode: review`, stop and ask; in
`auth_mode: auto`, skip the issue, record it in `human_decisions`, and keep
draining the rest of the queue.

## Spec Coverage Gate

Before planning implementation work, classify every open issue and linked PR:
use only the canonical `spec_status` values defined by
`checks/specrail_lib.py` as `SPEC_STATUSES`.

- `complete`: `product.md`, `tech.md`, and `tasks.md` all exist for the issue
- `needs_tasks`: product and tech specs exist, but `tasks.md` is missing
- `needs_spec`: product or tech spec is missing
- `umbrella_covered`: another complete GH spec explicitly includes the issue in
  scope, acceptance criteria, task plan, or linked work
- `exception_allowed`: dependency bump, focused CI fix, docs-only correction, or
  another explicitly justified small non-spec change

Implementation candidates are only `complete`, `umbrella_covered`, or
`exception_allowed`. For `needs_spec` and `needs_tasks`, route to the focused
SpecRail spec-writing or task-planning skill first. Do not implement from only
issue text, PR comments, or old chat context unless the user explicitly
authorizes a non-spec exception and the checkpoint records the reason.

Spec-drafting authorization depends on `auth_mode`:

- `auth_mode: auto`: drafting the missing spec or task packet and then
  implementing from it is authorized only when the current user message
  explicitly selected `implx auto` / `implx 自动`. Draft, self-check with the
  spec-writing skill's own gates, and continue to implementation in the same
  run, subject to the Spec/Impl Mix Gate. Escalate to `human_decisions` only
  for architecture-level rewrites or specs the issue lacks evidence to draft.
- `auth_mode: review`: draft the spec, then wait for human confirmation
  before implementing from it.

For `queue_mode: full_queue_drain`, `needs_spec` and `needs_tasks` are
actionable planning work, not completion. If no implementation-ready tranche is
available, select the smallest spec-writing or task-planning tranche instead of
ending the queue drain. Treat them as blockers only when the user limited the
run to implementation-only work, the issue lacks enough evidence to draft a
spec, or a human gate prevents spec creation.

## Queue Planning

Build an issue-to-PR plan:

- one issue per implementation PR by default
- several PRs per issue only when the task plan or risk justifies smaller slices
- combined PRs only when the specs explicitly share one acceptance surface
- `Refs #<issue>` for partial slices
- closing keywords only for the final slice that satisfies every acceptance
  criterion

When gating a partial slice, pass that expected issue to the read-only evidence
adapter with `--issue <issue>`. This verifies the live open issue and keeps any
other bounded closing references auditable without treating the partial target
as final or authorizing its closure.

Record the plan as:

```yaml
specrail_implementation_queue:
  overall_objective:
  queue_mode: bounded_tranche | full_queue_drain
  auth_mode: auto | review
  spec_coverage:
    complete:
    needs_tasks:
    needs_spec:
    umbrella_covered:
    exception_allowed:
  current_tranche:
  remaining_queue:
  issues:
    - issue:
      spec_dir:
      spec_status: complete | needs_tasks | needs_spec | umbrella_covered | exception_allowed
      spec_status_reason:
      acceptance_criteria:
      existing_prs:
      planned_prs:
      completion_mode: partial | final
      verification:
  gates:
    route_gate:
    pr_gate:
    review_threads:
    merge_authorization:
  context_budget:
    soft_stop_ratio: 0.50
    hard_stop_ratio: 0.65
    critical_stop_ratio: 0.75
  checkpoint:
    path:
    runtime_gate:
  stop_policy:
```

If `auth_mode` is not provided by the calling skill, default to
`auth_mode: review`. Never promote a run to auto mode from persisted repository
configuration; auto requires the explicit current-message invocation above.

For broad queues, always execute as bounded tranches. If the calling skill is
`implx`, or the user otherwise asks to finish actionable issues/PRs, set
`queue_mode: full_queue_drain` unless the prompt explicitly limits scope to one
issue, one PR, the current tranche, plan-only, status-only, or review-only work.
In that mode, choose the smallest mergeable current tranche, checkpoint it, then
continue selecting new implementation, spec-writing, or task-planning tranches
until the queue is drained or every remaining item is explicitly blocked,
deferred, waiting on CI, or needs human input.

A blocked or waiting current tranche does not stop full-queue drain. After
checkpointing that tranche, refresh remote truth and look for an independent
next tranche. Stop only when every remaining issue and PR is listed in
`remaining_queue` with `spec_status`, `blocker`, and `next_action`.

If the user only asks for a broad queue without explicit full-queue drain
authorization, choose the smallest mergeable tranche and leave the rest in the
checkpoint.

## Spec/Impl Mix Gate

Classify every PR the tranche creates as `pr_kind` on its checkpoint item:

- `spec`: only spec packets, docs, or planning artifacts
- `impl`: production code or tests
- `mixed_impl`: any PR that contains production code, even alongside specs

Rules:

- More than 3 consecutive `spec` PRs is a blocking violation unless the user
  explicitly confirmed a spec-only tranche; ask before exceeding the cap and
  record the quoted confirmation as `spec_only_declaration` (scope +
  conversation marker).
- Items without a `pr_kind` (blocked items, non-PR work) do not reset the
  streak; only `impl`/`mixed_impl` PRs do.
- Maintain `tranche_mix` counters (`spec_pr_count`, `impl_pr_count`,
  `consecutive_spec_only`) derived from the item records;
  `checks/runtime_ledger_gate.py` cross-checks them and blocks self-reported
  inflation.
- Never present spec PR counts as implementation progress in reports.

## Orchestration

Use this orchestration section and an available threads skill when the queue needs
parallel lanes, disjoint writable ownership, review-thread checks, CI polling,
merge gates, or closure audit.

For GitHub issue or PR queues, merge gates, reviewer lanes, and closure audit,
native thread dispatch is required whenever native subagent capability is
available. Before implementation, review, push, comment, or merge work, record:

```yaml
thread_dispatch_gate:
  explicit_thread_request:
  native_subagents:
  spawn_requirement:
  fallback_mode:
  planned_native_threads:
  native_thread_evidence:
    spawned_agents:
  no_spawn_reason:
```

If native subagents are available and `spawn_requirement: required`, spawn the
planned bounded native lanes before claiming threads were used. For PR merge
work, at least one read-only `reviewer` or `merge_reviewer` lane must be a real
native thread with recorded `agent_id_or_thread_id`, wait evidence, close
evidence, and collected output. The coordinator lane is not a reviewer thread.

If threads is unavailable, continue with the normal single-agent SpecRail flow
only after recording `fallback_mode: single_agent` and the reason; report that
no native threads were launched.

Keep ownership boundaries explicit:

- planner and reviewer lanes are read-only
- worker lanes own disjoint files or modules
- shared verification belongs to one coordinator
- dependent specs run serially

## Reviewer Lane Reuse

Reviewer lane input is scoped: the diff (or diff since the previously
reviewed head), the linked spec packet, and the prior-findings checklist.
Never forward coordinator conversation history into a reviewer lane. For
re-review after fixes, resume or message the existing reviewer lane first;
if the runtime cannot resume, spawn a `diff_only` lane instead of a new
full-history fork. Full reviews are capped at 2 rounds per PR unless a human
explicitly requests another full pass (see Review Rounds And Modes in
`skills/specrail-review-pr/SKILL.md`).

## Reviewer Lane Failures

A reviewer or merge-reviewer lane failure is a gate event, not an implementation
detail to hide. Failures include usage limits, crashes, zero output, or a lane
closed before it produced a complete review verdict.

When a reviewer lane fails:

- record `lane_failures[]` with lane id, failure kind, and observed marker
- downgrade the affected item to `blocked` or `needs_human` with
  `blocked_reason: reviewer_lane_failure`
- report the failure in the handoff/checkpoint before any merge decision
- recover only by launching a different independent reviewer lane, or by getting
  fresh explicit self-review authorization after reporting the failure

If recovery uses a new independent reviewer lane, record
`review_source: independent_lane` and keep the lane failure history in evidence.
If recovery uses self-review, record `review_source: self_review` and
`self_review_authorization` with actor, source, and scope from the current
conversation after the failure was reported. Prior queue-drain or generic merge
authorization does not cover a later self-review substitution unless it
explicitly scoped that failure path.

## Context Budget

For long queues, record a parent context budget before spawning lanes:

- default soft stop: 50% of the active context window
- default hard stop: 65% of the active context window
- default critical stop: 75% of the active context window

These are defaults, not universal limits. If the runtime exposes a different
budget or the user provides one, record the override.

At soft stop, do not spawn new lanes or broaden scope. At hard stop, finish the
current critical step, write the runtime checkpoint, and hand off to a fresh
parent thread. At critical stop, only write checkpoint and resume instructions.
For `queue_mode: full_queue_drain`, a hard-stop handoff preserves the full queue
objective and records the next actionable tranche; it does not redefine success
as completing only the current tranche.

### Bounded Tranche Hard Stop

`full_queue_drain` never runs as one unbounded session. It is a sequence of
bounded tranches, each with a hard budget declared at tranche start in the
checkpoint `budget` object (checkpoint_version 2):

- `basis`: `compaction` | `item_cap` | `both`. Compaction events are the
  primary observable degradation signal; use `item_cap` where the runtime
  does not expose compaction.
- `compaction_budget` default 1: stop before the second compaction.
- Record observed `compaction_count` as the session runs.

On budget exhaustion this is a normal terminal, not a failure: write the
checkpoint with `stop_reason: budget_exhausted` and a `resume_prompt`, then
hand off to a fresh session. Continuing past the budget requires an explicit
user `budget_override` recorded with quoted scope and a conversation marker;
`checks/runtime_ledger_gate.py` blocks over-budget continuation without one
and blocks version-2 drain checkpoints that declare no budget. Reviewer
lanes stay bounded (the audited well-behaved lanes stayed under ~2M tokens);
lanes do not inherit the parent budget.

Do not read raw `~/.codex/sessions` logs, old parent transcripts, or broad
session JSONL as queue state. Use the checkpoint, repo-local run logs, and fresh
remote truth.

## Output Firewall

Large output commands are allowed only when raw stdout and stderr go to artifact
files. The coordinator may read exit code, a short tail, targeted grep output,
and the artifact path.

Default rules:

- no raw `gh run view --log` output in parent context
- no raw full `cargo test` or full workspace test output in parent context
- no broad `rg` or `git grep` across `.codex`, `.claude`, `target`,
  `node_modules`, session JSONL, or log files
- parent stdout tail target: 150 lines or less
- subagent final output target: 150 lines or less

Prefer artifact paths such as `artifacts/logs/<tranche>/cargo-test.log` and
summaries such as `artifacts/logs/<tranche>/ci-summary.md`.

## Runtime Checkpoint

For long queues, create or update an optional local runtime checkpoint before:

- spawning writable lanes
- pushing or opening PRs
- waiting on CI or long local tests
- requesting merge review
- compacting, handing off, or closing the parent thread
- selecting the next tranche in a full-queue drain loop

Use `templates/tranche_checkpoint.md` as the shape and validate concrete JSON
checkpoints with:

```bash
python3 checks/runtime_ledger_gate.py --checkpoint .specrail/runtime/current.json
```

The runtime checkpoint is a local handoff layer only. GitHub issues, PRs,
labels, reviews, branches, and SpecRail spec packets remain the durable workflow
truth.

For `queue_mode: full_queue_drain`, the checkpoint must record the overall
objective, spec coverage, current tranche, completed items, remaining queue,
explicit blockers, and next resume action. `needs_spec`, `needs_tasks`,
`eligible_impl`, `waiting_ci`, and `needs_review` do not count as drained while
the checkpoint status is `complete`; they require a next action or a non-drain
handoff status. Resume from the checkpoint plus fresh remote truth; do not
recover queue state from old parent transcripts.

## Goal Use

Codex Goal can control the current tranche only when the user explicitly asks
for goal-controlled work, gives a token or time budget, or explicitly frames the
run as long-running goal work. Otherwise record a `goal_candidate` in the
checkpoint but do not silently create a goal.

Goal never replaces the runtime checkpoint, GitHub truth, or SpecRail gates.

## Implementation

For each issue slice:

1. Use `skills/specrail-implement/SKILL.md` for the scoped implementation.
2. Search before adding files, public APIs, workflow assets, schemas, templates,
   or policies.
3. Run duplicate-work evidence collection and the implementation route gate
   before creating a new implementation PR.
4. Implement only acceptance criteria from the linked spec and task plan.
5. Add or update tests that prove the changed behavior.
6. Keep machine IDs, paths, commands, states, routes, and JSON keys in English.
7. Keep human-facing text in the selected locale.

## Review And Verification

Before a PR is considered ready:

- run focused tests for touched behavior
- run repository deterministic checks
- run `python3 checks/check_workflow.py --repo .`
- run `python3 checks/check_workflow.py --repo . --spec-dir docs/specs/GH<issue>`
  when the spec packet changed
- use `skills/specrail-check-impl-against-spec/SKILL.md` to compare the PR or
  diff to the linked specs
- use `skills/specrail-pr-gate/SKILL.md` before reporting merge readiness

For GitHub PRs, current evidence must include:

- PR head SHA
- CI/check rollup
- review decision when available
- independent reviewer or merge-reviewer lane evidence
- native reviewer thread evidence when native subagents are available
- `review_source` (`independent_lane` or `self_review`)
- `lane_failures[]`, empty when no reviewer lane failed
- `self_review_authorization` when `review_source: self_review`
- GraphQL review-thread state
- per-thread resolver identity and resolver lane role
- gate-query completion timestamp and gate-query head SHA from the serial
  `pr_gate.py` run
- merge state
- linked issue or closing reference intent
- merge authorization per `auth_mode` (see Merge Authorization)

The runtime checkpoint must not mark a PR item `complete`, `merged`,
`merge_ready`, or `ready_to_merge` unless `checks/runtime_ledger_gate.py` accepts
the checkpoint. When the gate is evaluating a merged or merge-ready PR, local
`pr_gate.evidence` must exist and either be an allowed PR gate result JSON or a
raw PR evidence JSON that re-evaluates to `allowed`.

### Reviewer-Lane Failure Protocol

A reviewer or merge-reviewer lane that dies before returning a usable result —
usage limit, crash, zero output, or closed early — is a blocking event, not a
license to continue:

1. Record the failure on the checkpoint item as `lane_failures[]` with
   `lane_id`, `failure_kind` (`usage_limit` | `crash` | `zero_output` |
   `closed` | `other` + `detail`), and the observed marker.
2. Downgrade the item to `blocked` or `needs_human` with `blocked_reason`
   (for example `reviewer_lane_failure`) and report it in the handoff, or
3. Recover by spawning a new independent reviewer lane; the retry lane must be
   a different lane than the failed one and its review recorded with
   `review.review_source: independent_lane`.

Silent self-review substitution is forbidden. `review.review_source:
self_review` never satisfies the independent-review requirement on its own;
merging on self-review requires explicit `self_review_authorization` on the
item, recording the quoted user scope and a conversation marker. Declare the
review source when collecting evidence
(`python3 checks/github_pr_evidence.py ... --review-source independent_lane`);
`pr_gate.py` blocks evidence without `review_source` and
`runtime_ledger_gate.py` blocks unauthorized self-review merges and
unreported lane failures.

### Merge Authorization

`auth_mode: auto`:

- The current user message must explicitly say `implx auto` / `implx 自动`.
  That invocation is the standing merge authorization for the run. Do not ask
  per-PR merge questions.
- Merge when ALL current evidence is green: CI/check rollup passing, PR gate
  passed, review threads resolved, reviewer-lane evidence present, merge state
  clean. Any evidence gap means skip the PR, record the gap in
  `remaining_queue`, and keep draining.
- Use closing keywords on final slices; after merge, close issues whose
  acceptance criteria are fully merged. Merged-but-open issues found during
  closure audit are closed with a comment linking the merged PRs.
- Human-gate items (duplicate-ownership conflicts, maintainer waivers, probe
  or time-window gates, conflicting review feedback, destructive or
  irreversible actions) never block the queue: skip, continue, and report them
  once in a final `human_decisions` list with a recommended action each.
- Auto mode does not weaken reviewer-lane requirements, the self-review
  authorization rules, the Bounded Tranche Hard Stop, or the runtime ledger
  gate. Standing merge authorization is not self-review authorization.

`auth_mode: review`:

- Do not merge without explicit human authorization in the current
  conversation, per PR.

### Safe Merge Path

Merging must survive branches that are checked out in local worktrees and
must never report an outcome without remote confirmation:

1. Run the merge from a neutral cwd with an explicit repo target
   (`gh pr merge <n> --repo OWNER/REPO ...`).
2. On local ownership failures (for example `branch ... is checked out at
   ...` or a worktree lock; the class is "local ownership failure", the
   messages are examples), fall back to
   `gh api -X PUT /repos/{owner}/{repo}/pulls/{n}/merge` using a merge
   method the repo allows (query merge settings first). Do not delete or
   move the offending worktree — it may belong to another live session.
3. Always confirm the outcome with a remote query
   (`gh pr view <n> --json merged,mergeCommit`) before recording success or
   failure, and write the result into the gate evidence as `merge_record`
   (`merge_path`: `gh_pr_merge` | `api_fallback` | `merged_by_other`,
   `remote_confirmed`, `merge_commit_sha`). A PR merged by someone else is a
   valid confirmed terminal (`merged_by_other`).
4. Post-merge: delete the remote branch as a separate step and record
   `branch_deletion_outcome`; run `git worktree prune` in each local
   checkout the tranche used and list stale or removed worktrees in the
   closure report.

`checks/pr_gate.py` blocks merge records without `merge_path` or without
`remote_confirmed: true`.

## Boundaries

- In `auth_mode: auto`, merge only on complete current evidence; evidence gaps
  mean skip and report, not ask.
- In `auth_mode: review`, do not merge without explicit human authorization and
  current PR-gate evidence.
- Do not dispatch review-thread/pr_gate queries and the merge command in the
  same parallel tool batch or parallel lane; the gate query must complete first.
- Do not let an implementation lane or orchestrator resolve reviewer-lane
  review threads. If the reviewer lane is unavailable, route through the GH-59
  reviewer-lane failure path or a human decision.
- Do not silently replace a failed reviewer lane with coordinator self-review.
  Self-review can proceed only after the failure is reported and fresh scoped
  self-review authorization is recorded.
- Do not treat green CI as merge readiness without review-thread and merge-state
  truth.
- Do not close an issue from a partial implementation.
- Do not replace an existing maintainer-writable PR unless it is stale, unsafe,
  unwritable, or a human approves replacement.
- Do not vendor a local threads skill into SpecRail.

## Output

Report:

- overall objective, queue mode, current tranche, and remaining queue
- issue-to-PR mapping
- PR links, head SHAs, and merge commits when merged
- acceptance criteria covered or remaining
- tests and deterministic checks run
- review-thread, CI, merge-state, and PR-gate evidence
- issues still open and why
- `human_decisions`: the consolidated list of items needing a human choice,
  each with a recommended action (auto mode reports this once at the end
  instead of asking mid-run)
- local dirty or stale worktree state

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
