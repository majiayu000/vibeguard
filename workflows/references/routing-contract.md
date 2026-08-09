# Routing Contract

Use the smallest workflow that safely delivers the user's request.

## Direct Work

Execute directly when the goal, scope, and verification are clear. Small bugs, focused docs, tests, and mechanical changes do not require a routing artifact, spec, or handoff packet.

## Plan First

Write a concise plan only for major architecture, migrations, cross-system policy changes, or when the user explicitly asks for one. A plan should name the outcome, boundaries, ordered steps, verification, and true blockers. It does not require fixed metadata fields.

## Clarify First

Ask one focused question only when an unknown choice would materially change the result, authorization, or safety. Continue with reasonable assumptions when the missing detail is low risk and can be verified.

## Changes During Work

When the user changes scope, restate the new goal and update the active plan if one exists. Do not build a routing packet.

## Constraints

- No file-count routing rules.
- No mandatory execution handoff.
- No routine runtime-pinning snapshot.
- No automatic delegation lane.
- No process artifact whose only purpose is validating another process artifact.
