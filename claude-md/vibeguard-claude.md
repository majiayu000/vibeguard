## Claude Code host guidance

- Every profile uses the compact shared core. Profiles select hooks, not a larger rule payload. Read detailed rules from the installed source only when the task needs them; preserve user-managed native rules.
- Claude Code hooks can cover read/search loops as well as Bash and file changes; treat hook output as guard feedback, not proof that the task is complete.
- VibeGuard commands are available under `/vibeguard:*` with `/vg:*` shortcuts when the command bundle is installed.
- Use the current project's own verification commands instead of assuming a language-wide default.
