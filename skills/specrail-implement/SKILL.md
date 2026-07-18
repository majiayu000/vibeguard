---
name: specrail-implement
description: Use when implementing a SpecRail-governed issue after the implementation gate. Executes the scoped task plan, keeps changes tied to linked specs and acceptance criteria, runs deterministic verification, and preserves human approval, merge, and security boundaries.
---

# SpecRail Implement

Use this skill for the `implement` route.

## Steps

1. Read the linked issue, product spec, tech spec, and task plan.
2. Run the implementation route gate when available:

```sh
python3 checks/route_gate.py --repo . --route implement --issue <issue-number> --state ready_to_implement --json
```

3. If the gate returns `needs_human` or `blocked`, stop and report the missing
   evidence or gate.
4. Implement only the scoped tasks. Search before adding files, workflows,
   schemas, templates, policies, or public APIs.
5. Keep machine-facing IDs in English and human-facing text in the selected
   locale.
6. Run focused verification for touched behavior, then run the pack check when
   workflow assets changed:

```sh
python3 checks/check_workflow.py --repo .
```

7. Record changed files, commands, results, and remaining human gates.

## Boundaries

- Do not provide final approval.
- Do not merge without explicit human authorization and a passing PR gate.
- Do not publish secrets or private security details.
- Do not weaken tests or deterministic checks to make implementation pass.

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
