---
name: specrail-review-pr
description: Use when performing an advisory SpecRail PR review. Checks linked issue/spec evidence, route gates, verification evidence, review-thread state, human-gate preservation, and implementation quality without granting final approval or merging.
---

# SpecRail Review PR

Use this skill for the `review_pr` route.

## Steps

1. Read the PR, linked issue, product spec, tech spec, task plan, and local diff.
2. Confirm the PR has current evidence for linked work, verification, CI, review
   state, and review threads when available.
3. Run the review route gate when available:

```sh
python3 checks/route_gate.py --repo . --route review_pr --issue <issue-number> --pr <pr-number> --state impl_pr_open --json
```

4. Inspect for behavioral regressions, missing acceptance coverage, test gaps,
   silent degradation, security risk, and human-gate bypasses.
5. Lead with findings ordered by severity and cite exact files or lines.
6. When producing a review artifact, use a top-level body with `## Summary` and
   `## Verdict`, keep inline comments bound to real diff `path` / `line` /
   `side` values, and only add `start_line` / `start_side` together for an
   inclusive diff range. Suggested changes must be non-empty and appear only on
   RIGHT-side comments, either through a `suggestion` field, a fenced
   `suggestion` block, or both.
7. Validate review artifacts against the diff when the gate exists:

```sh
python3 checks/review_json_gate.py --repo . --review artifacts/review/pr-<pr-number>.json --diff <patch> --json
```

8. If merge readiness is requested, route to
   `skills/specrail-pr-gate/SKILL.md`.

## Review Rounds And Modes

Record `review_round` and `review_mode` in the review result JSON:

- `full`: the whole PR is reviewed. Allowed for rounds 1-2. A full review
  past round 2 requires a quoted `human_full_review_request`; otherwise
  `checks/review_json_gate.py` blocks it.
- `resumed`: the same reviewer lane continues with its prior context and
  re-checks its earlier findings.
- `diff_only`: a fresh pass over only the changes since `base_head_sha`
  (the head reviewed in the prior round; required field).

`resumed` and `diff_only` rounds require `review_round >= 2` and a
`prior_findings[]` checklist where every prior finding carries a status
(`resolved` | `unresolved` | `obsolete`). Record `pr` and `head_sha` as the
grouping key so rounds for the same PR can be ordered.

## Thread Resolution Ownership

Reviewer lanes may resolve review threads only after re-checking that the
finding is fixed or no longer applies. A reviewer lane may resolve its own
thread, a successor reviewer lane may resolve after re-review, and a human
maintainer may resolve directly.

Implementation lanes and orchestrators must not call `resolveReviewThread` for
reviewer-lane findings. They may reply with context and push fixes, but the
resolution action stays with the reviewer or human.

## Boundaries

- Treat the review as advisory.
- Do not grant final approval.
- Do not merge or mark human gates complete.
- Do not resolve reviewer-lane threads from an implementation or coordinator
  role.
- Do not disclose private security details publicly.

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
