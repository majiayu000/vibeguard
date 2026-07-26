# Growth and Architecture Roadmap (Draft Spec)

Status: Draft spec — verify priority and open a GitHub issue per workstream before implementation.
Date: 2026-07-26

## Problem

VibeGuard's defense stack (Rust runtime hooks, 126 layered rules, static guards,
paired with/without eval, precision tracking, cross-session learning) is ahead of
comparable tooling, but adoption does not reflect that. The bottlenecks are
positioning, distribution friction, and unproven-to-outsiders effectiveness —
not missing capability.

## Goal

Make VibeGuard the default guardrail layer for AI coding agents: installable in
under one minute, valuable in the first session, and backed by published,
reproducible effectiveness numbers.

## Non-goals

- Rewriting the runtime or rule engine; both are adequate.
- Adding new rule surface area before the distribution and evidence gaps close.
- SaaS/hosted offering; everything below stays local-first.

## Workstreams (priority order)

### WS1 — One-command install

Today the supported path is `git clone` + `setup.sh`, which makes the repository
the installation medium. Target end state:

- Single command install: `brew install vibeguard` and/or `npx vibeguard init`
  (or `bunx`), plus Claude Code plugin-marketplace listing.
- The release binary (already built, checksummed, provenance-attested) becomes
  the distribution unit; rules/hooks ship inside it or are fetched on first run.
- The git checkout remains the development source only.

Done-when: a fresh machine goes from nothing to a verified install (equivalent
of `setup.sh verify-install` passing) with one command and no repository clone.

### WS2 — Public effectiveness benchmark

The paired with/without side-effect gate (GH686, PR #696) is the foundation.
Target end state:

- A reproducible `vibeguard bench` that injects representative failure classes
  (invented APIs, duplicate modules, swallowed exceptions, dangerous shell/git
  ops, unverified "done" claims) and reports interception rate, false-positive
  rate, and hook latency.
- Headline numbers published in README and regenerated in CI per release.

Done-when: README shows a benchmark table any user can reproduce with one
command from a released binary.

### WS3 — Repositioning: agent firewall, not a two-tool rule pack

- Narrative shifts from "rules for Claude Code and Codex" to "the firewall
  between AI coding agents and your codebase".
- Adapter surface documented so additional hosts (Cursor CLI, Gemini CLI,
  opencode) can be added without touching the rule/guard core; ship at least
  one new host adapter to prove the seam.
- README first screen reduced to: one-line positioning, a 30-second intercept
  demo GIF, the one-command install, the benchmark table. Operational detail
  (provenance modes, fallbacks, doctor internals) moves under `docs/`.

Done-when: a first-time visitor can understand, install, and see a real
interception within five minutes without reading past the first screen.

### WS4 — Rule packs as an ecosystem

- Stabilize the pack format (`packs/` + `schemas/`) as a published contract.
- `vibeguard add <pack>` installs a third-party pack; core packs stay curated
  with precision data attached.
- Precision tracking gates defaults: rules below a precision floor ship as
  warnings, not blocks (protects against the number-one uninstall reason:
  false-positive fatigue).

Done-when: an external contributor can author, publish, and install a pack
without modifying this repository.

### WS5 — Visible weekly value

- The opt-in weekly report (PR #572) becomes the default retention surface:
  "this week VibeGuard blocked N dangerous ops, caught M invented APIs" with a
  shareable summary.

Done-when: a default install produces a weekly summary without extra setup.

### WS6 — Tiered semantic defense (differentiation moat)

Layered detection depth, each tier opt-in above the last:

- L1 (exists): regex/AST guards, microsecond budget.
- L2: semantic checks via a small local/cheap model — "does this API exist in
  this project's dependencies", "was this test assertion weakened".
- L3 (exists in part as W-rules): session-level behavior detection — repeated
  failed fixes, completion claims without verification — moving from rule text
  to runtime enforcement signals.
- Cross-session learning closes the loop: corrections observed in practice
  become candidate rules with tracked precision.

Done-when: L2 ships behind a flag with measured latency and precision, and at
least two W-rules are enforced from runtime signals rather than prompt text.

## Sequencing

WS1 and WS3 unblock adoption and ship first (WS3's README cut is cheap and can
land with WS1). WS2 lands next and feeds launch material. WS4–WS6 follow;
none of them pay off while installation still requires cloning the repository.

## Risks

- False-positive fatigue: every workstream that adds detection must attach
  precision data before enabling blocking defaults (WS4 floor applies globally).
- Scope creep: WS6 L2 must hold a hard latency budget or it degrades the
  core promise (fast hooks).
- Windows remains smoke-contract only; WS1 packaging should not promise more
  than CI verifies.
