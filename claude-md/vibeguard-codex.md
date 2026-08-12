## Codex host guidance

- Repository-level and nested `AGENTS.md` files provide project-specific facts and take precedence over these global defaults.
- Managed VibeGuard skills are installed under `$CODEX_HOME/skills/`, defaulting to `~/.codex/skills/`; use a skill only when its activation conditions match the task.
- Native Codex hooks cover Bash and `apply_patch` gates plus Stop events. Read, Glob, and Grep hook surfaces are unavailable, so do not claim those loops were mechanically intercepted.
- Claude-only slash commands, `/clear`, native rule paths, and compaction behavior are not part of this Codex contract.
