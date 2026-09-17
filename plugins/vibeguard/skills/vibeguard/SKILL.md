---
name: vibeguard
description: Use when the user explicitly asks to install, uninstall, diagnose, or look up rules in VibeGuard. Ordinary coding, review, build failures, and generic safety requests do not activate this skill.
---

# VibeGuard

Use `~/.vibeguard/bin/vibeguard-runtime`. If absent, explain that the Rust CLI must be built or installed from the repository; do not invent another executable or an installation result.

For rule questions, list with `rules`, then read the relevant ID or category. These are scoped review topics, not automatic blocking claims.

For diagnostics, run `status codex`. Distinguish registration, executable mode bits, last observation, and unknown host trust. A tool result does not prove the current task is verified.

For explicitly requested installation/removal, use `install codex` or `uninstall codex`. Existing authorization is sufficient. Git protection is separate and requires the requested repository. Do not edit host configuration by hand or register hooks during rule lookup.

Respect scope and host permissions. VibeGuard is not a sandbox, agent-loop replacement, or mandatory workflow for unrelated work.
