---
name: specrail-release-note
description: Use when drafting a SpecRail release note after a linked PR has merged. Summarizes user-visible changes, verification, linked issues, risks, and rollout notes while preserving release and security human gates.
---

# SpecRail Release Note

Use this skill for the `draft_release_note` route.

## Steps

1. Confirm the PR is merged and identify the linked issue, commits, specs, and
   verification evidence.
2. Run the release-note route gate when available:

```sh
python3 checks/route_gate.py --repo . --route draft_release_note --issue <issue-number> --pr <pr-number> --state merged --json
```

3. Draft a concise release note in the selected locale.
4. Include user-visible change, linked work, verification, migration or rollback
   notes, and any known limitations.
5. Keep stable machine-facing IDs, paths, commands, and JSON keys in English.

## Boundaries

- Do not publish a release.
- Do not mark the release human gate complete.
- Do not include private security details in public notes.
- Do not claim closure for unverified issues or PRs.

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
