## Claude Code host guidance

- The compact shared core is always present. `full` and `strict` profiles may also expose matching native rule files through `~/.claude/rules/vibeguard/`.
- Claude Code hooks can cover read/search loops as well as Bash and file changes; treat hook output as guard feedback, not proof that the task is complete.
- VibeGuard commands are available under `/vibeguard:*` with `/vg:*` shortcuts when the command bundle is installed.
- Use the current project's own verification commands instead of assuming a language-wide default.
