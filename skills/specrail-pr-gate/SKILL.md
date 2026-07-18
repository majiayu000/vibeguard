---
name: specrail-pr-gate
description: Use before reporting a SpecRail PR as merge-ready. Collects read-only PR evidence, runs the offline PR gate, checks linked work, current head SHA, CI, review decision, review threads, merge state, and human merge authorization without merging.
---

# SpecRail PR Gate

Use this skill before saying a PR is merge-ready.

## Steps

1. Collect current PR evidence. Prefer the read-only adapter when available:

```sh
python3 checks/github_pr_evidence.py --github-repo <owner/repo> --pr <pr-number> --review-source independent_lane --json > <evidence.json>
```

For a partial slice with a standalone `Refs #<issue-number>` directive, pass
the expected issue explicitly:

```sh
python3 checks/github_pr_evidence.py --github-repo <owner/repo> --pr <pr-number> --issue <issue-number> --review-source independent_lane --json > <evidence.json>
```

The expected issue must exist in the same repository and remain open. Other
closing references may coexist; the adapter records all of them without
redirecting the explicit target. A verified `partial` relation satisfies only
linked-work evidence and never authorizes final completion or issue closure.

2. Run the offline gate:

```sh
python3 checks/pr_gate.py --repo . --evidence <evidence.json> --json
```

3. Confirm evidence includes linked issue and, for new adapter output, a
   self-consistent `issue_reference`; also confirm current PR head SHA, gate-query
   completion timestamp, gate-query head SHA, CI/check rollup, review decision,
   review source, lane failures, review-thread resolution, merge state, and human
   merge authorization.
4. Interpret decisions precisely:
   - `allowed`: evidence satisfies the local merge-readiness policy.
   - `needs_human`: deterministic evidence passed, but a human gate is missing.
   - `blocked`: do not merge.
5. Report the evidence file path, decision, blockers, and stale or missing data.

## Serial Gate Ordering

The PR gate query must complete before any merge command, API call, or merge
lane is dispatched. Do not issue the GraphQL review-thread query, PR evidence
collection, `pr_gate.py`, and merge command in the same parallel tool batch or
parallel threads lane.

Required evidence:

- `gate_query_completed_at`: when the current gate query finished.
- `gate_query_head_sha`: the head SHA observed by that gate query.
- `review_source`: `independent_lane` for a real reviewer/merge-reviewer lane,
  or `self_review` when a lane failure was reported and self-review was
  explicitly authorized.
- `lane_failures`: an array, empty when no reviewer lane failed.
- `merge_dispatched_at` and `merge_head_sha` when auditing a merge record after
  dispatch.

If `review_source` is `self_review`, evidence must include
`self_review_authorization` with actor, source, and scope from the current
conversation after the lane failure was reported. General queue-drain or merge
authorization does not satisfy this self-review exception.

GitHub exposes `resolvedBy` for review threads, but not the SpecRail lane role.
When resolved threads exist, pass lane-roster evidence through
`--resolver-role-map` so resolver logins can be mapped to `resolver_role`.

If the PR head changes, new review activity appears, CI changes, or merge is
deferred long enough that the evidence may be stale, collect fresh PR evidence
and rerun `pr_gate.py` before merging.

## Boundaries

- Do not merge from this skill.
- Do not dispatch gate queries and merge in parallel.
- Do not treat green CI alone as merge readiness.
- Do not ignore unresolved review threads.
- Do not replace maintainer final review or human merge authorization.

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
