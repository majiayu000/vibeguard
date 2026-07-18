# Product Spec

## Linked Issue

GH-541

## User Problem

VibeGuard defines rule U-32: more than 15 effective constraints degrade agent performance, and more than 30 must block. Yet for Claude Code it injects the full ~126-rule set (full text of `rules/claude-rules/**`) into every session — about 4× its own block threshold. The compact Codex path (~82-line L1-L7 + 16-row table) stays in budget; only the Claude path over-injects. The product's flagship anti-bloat rule is broken by its own rule-delivery mechanism, and it even ships a hook (`count_active_constraints.sh`) that would fire on this default payload.

## Goals

- Bring the default Claude-session constraint payload within (or near) U-32's budget.
- Keep always-on critical constraints (security, verification, core workflow) present by default.
- Load lower-frequency, language- or path-specific rules on demand rather than all at once.

## Non-Goals

- Deleting rules or reducing the total rule set.
- Changing the Codex compact path (already in budget).
- Rewriting rule content (this is about delivery, not authorship).

## Behavior Invariants

1. The default Claude-session payload injects a compact core (target ≤ ~30 effective constraints), not all ~126 rules in full text.
2. The compact core always includes the always-on constraints: security-critical rules, verification rules, and the L1-L7 layer summary.
3. Language/path-scoped rule files (`rules/claude-rules/<lang>/`) are available to load when the session touches matching files, rather than being injected up front.
4. A user can opt into full-set injection via the `strict` profile.
5. `count_active_constraints.sh` run against the default payload does not exceed U-32's block threshold.

## Acceptance Criteria

- [ ] Default install injects the compact core, not the full rule text (verified by measuring the injected payload).
- [ ] `count_active_constraints.sh` on the default payload reports within the U-32 budget (no block-level violation).
- [ ] The `strict` profile still loads the full set for users who want it.
- [ ] Security/verification/core rules remain present in the default payload.

## Edge Cases

- Mixed-language edit session (must still surface cross-cutting rules from the core).
- User with `strict` profile expecting full load (must be unchanged).
- Path-scoped loading unavailable in a given host — must degrade to the compact core, not to nothing.

## Rollout Notes

This changes what every Claude session sees by default. Communicate clearly: the full rule set is still installed and available, but not all injected at once. Provide the `strict` opt-in for users who prefer the old behavior. Measure agent-compliance before/after if possible to validate the U-32 premise on this repo's own payload.
