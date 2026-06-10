---
name: vibeguard
description: Use when the user asks Codex to apply VibeGuard anti-hallucination rules, inspect VibeGuard status, or route a task through VibeGuard preflight/review/check workflows.
---

# VibeGuard

VibeGuard is an anti-hallucination guardrail system for AI-assisted
development. This Codex App plugin is a discovery and operator entrypoint for
the existing VibeGuard repository; it does not silently install hooks during
plugin load.

## When to Activate

- User mentions VibeGuard, anti-hallucination rules, guardrails, or Codex hook status.
- User asks for a VibeGuard preflight, review, check, build-fix, or workflow route.
- User asks how to install or verify VibeGuard from Codex App.

## Red Flags

- **Silent global mutation** - plugin discovery must not rewrite `~/.codex` or hook files.
- **Rule-only fix** - adding prose without a guard, hook, test, or eval creates false confidence.
- **Unverified completion** - a VibeGuard setup or guard claim without fresh command output is not complete.

## Checklist

- [ ] Locate the VibeGuard repository checkout before running setup or guard commands.
- [ ] Use `plugins/vibeguard/scripts/vibeguard-plugin.sh check --strict` for install health.
- [ ] Use explicit install commands, such as `install --yes`, before modifying user-level Codex config.

## Usage

For setup, status, or uninstall work, read the `vibeguard-setup` skill first.
For repository development work, follow the root VibeGuard `AGENTS.md` and the
existing `skills/vibeguard/SKILL.md` in the source checkout.
