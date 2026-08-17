## Codex host guidance

- Repository-level and nested `AGENTS.md` files provide project-specific facts and take precedence over these global defaults.
- VibeGuard does not install bundled Codex skills into `$CODEX_HOME/skills/`; preserve user-managed skills there and use them only when their activation conditions match the task.
- Codex hook installation follows the selected setup profile: every profile covers native Bash and `apply_patch` gates; `full` and `strict` additionally install `post-build-check` and `Stop` hooks (`stop-guard` and `learn-evaluator`). Read, Glob, and Grep hook surfaces are unavailable, so do not claim those loops were mechanically intercepted.
- Claude-only slash commands, `/clear`, native rule paths, and compaction behavior are not part of this Codex contract.
