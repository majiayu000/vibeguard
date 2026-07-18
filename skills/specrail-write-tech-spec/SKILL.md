---
name: specrail-write-tech-spec
description: Use when writing or updating a SpecRail technical spec for a linked issue. Produces the numbered `tech.md` spec from the locale-appropriate template, translating accepted product behavior into design, affected files, risks, verification, and rollback without starting implementation.
---

# SpecRail Write Tech Spec

Use this skill for the technical half of the `write_spec` route.

## Steps

1. Read the linked issue and `docs/specs/GH<issue-number>/product.md`.
2. Read the relevant tech spec template from
   `templates/<locale>/tech_spec.md` or `templates/tech_spec.md`.
3. Run the local gate when available:

```sh
python3 checks/route_gate.py --repo . --route write_spec --issue <issue-number> --state ready_to_spec --json
```

4. Explore the codebase first, then write `docs/specs/GH<issue-number>/tech.md`.
5. Ground the plan in codebase context: relevant files, current behavior, and
   why each area changes or stays unchanged, following the anchor discipline
   below.
6. Map every product behavior invariant to an implementation area and a
   verification, following the full-coverage rule below.
7. Describe the proposed design, data flow, touched components, edge cases,
   migration or compatibility risks, verification plan, and rollback plan.
8. Name deterministic checks that prove the design was implemented.

## Anchor discipline

Every file reference in Codebase Context is a claim; verify it before writing
it down.

- Write `path:line` anchors only after confirming them with Read or grep in
  the current working tree. Do not guess paths, line numbers, function names,
  or config keys from memory.
- If an anchor cannot be verified, either drop the row or mark it explicitly
  as "待定位 / to locate" — never leave a plausible-looking guess.
- Anchors describe the tree at spec-writing time. When implementation later
  moves the code, the implementer updates their own references; the spec is
  not retroactively patched.

## Full-coverage mapping

The Product-to-Test Mapping table must enumerate every `B-xxx` from
`product.md` — no orphan invariants.

- One row per invariant (grouping several IDs in one row is acceptable only
  when they share the same implementation area and the same verification).
- Verification is an executable command or a concrete manual check. Empty
  cells, "TBD", and "covered by tests" without naming the test are all
  violations.
- Boundary-checklist verdicts marked N/A do not receive `B-xxx` IDs and do not
  appear in the mapping; their reason already lives in `product.md`. If an
  item has a `B-xxx` ID, it is an invariant and must be mapped even when its
  prose contains the text "N/A".

Example rows at the expected precision:

> | Behavior invariant | Implementation area | Verification |
> | --- | --- | --- |
> | B-006 authorized self_review with empty lane_failures is blocked | `checks/pr_gate.py` merge-claiming branch | negative fixture: `self_review + valid auth + lane_failures: []` → gate exits blocked; test names the fixture |
> | B-009 negative fixtures are schema-valid | `examples/fixtures/` | `pytest tests/test_specrail_schema.py` passes on the new fixtures |

## Boundaries

- Do not start implementation from the tech spec step.
- Do not claim spec approval; report missing approval as a human gate.
- Preserve dry-run and advisory defaults for automation.
- Keep stable machine-facing IDs in English.

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
