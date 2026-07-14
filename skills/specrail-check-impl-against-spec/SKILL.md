---
name: specrail-check-impl-against-spec
description: Use when comparing a SpecRail implementation, diff, or PR against its linked issue, product spec, technical spec, and task plan. Reports acceptance coverage, mismatches, omitted tasks, extra scope, and verification gaps without approving or merging.
---

# SpecRail Check Implementation Against Spec

Use this skill when the question is whether implementation matches the spec.

## Steps

1. Read the linked issue, `product.md`, `tech.md`, `tasks.md`, and the diff or
   PR under review.
2. Map every acceptance criterion and task ID to implementation evidence,
   verification evidence, or a missing item.
3. Identify extra behavior not requested by the spec.
4. Check that stable IDs, paths, JSON keys, states, and commands remain in
   English.
5. Report results as:
   - covered
   - missing
   - mismatched
   - extra scope
   - needs human decision
6. Recommend the smallest corrective action for each gap.

## Boundaries

- Do not treat partial coverage as approval.
- Do not rewrite the spec to match an implementation unless the user asks for a
  spec revision.
- Do not merge or provide final approval.

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
