## Codex host guidance

- Repository-level and nested `AGENTS.md` files provide project-specific facts and take precedence over these global defaults.
- When managed VibeGuard skills are installed, they live under `$CODEX_HOME/skills/`, defaulting to `~/.codex/skills/`; use a skill only when its activation conditions match the task.
- Every Codex setup profile covers native Bash and `apply_patch` gates. Only the `full` and `strict` profile contracts add `Stop` hooks, including `stop-guard`; `minimal` and `core` do not promise Stop coverage. Read, Glob, and Grep hook surfaces are unavailable, so do not claim those loops were mechanically intercepted.
- Claude-only slash commands, `/clear`, native rule paths, and compaction behavior are not part of this Codex contract.
