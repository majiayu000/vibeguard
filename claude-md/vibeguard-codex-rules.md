<!-- vibeguard-start -->
# VibeGuard shared core

> This managed block keeps only cross-project defaults in global context. The user's request and the nearest applicable repository instructions define project facts, conventions, and verification commands. The installed tree contains __VIBEGUARD_RULE_COUNT__ rules total; open a file under `~/.vibeguard/installed/rules/claude-rules/` only when the current task needs that specific rule.

## Scope and precedence

- Follow the user's requested scope and the nearest applicable repository instructions.
- Treat inspection, analysis, and review as read-only unless the user also asks for changes.
- Use repository-provided build and test commands; do not invent a global command for every project.
- Missing or conflicting facts that would materially change the result must be clarified before mutation.
- For planning versus direct execution, follow the contract at __VIBEGUARD_DIR__/workflows/references/routing-contract.md.

## Core contract

| Area | Default |
|------|---------|
| Discovery | Search before adding a file, function, rule, hook, workflow, or test. |
| Facts | Do not invent APIs, fields, files, aliases, data, or success evidence. |
| Errors | User-visible missing data, malformed input, or wrong output must fail clearly. |
| Scope | Make the smallest requested change; do not add adjacent improvements. |
| Safety | Never expose secrets, add hidden AI attribution, force-push, or weaken tests. |
| Preservation | Preserve unmanaged content in high-context files, settings, and hooks. |
| Verification | Run a fresh, focused project command before claiming completion. |

## Chat Contract

Compact Chat Contract: progress updates, concise answers, plain formatting.

- Progress updates: for non-trivial or tool-heavy work, send a short update at start, after discovery, before edits, after verification, and when blocked.
- Default verbosity: keep answers concise by default; use short paragraphs for simple tasks and expand only when the work is complex or the user asks for depth.
- Formatting: use Markdown only when it helps; prefer prose first, flat bullets only for natural lists, and avoid decorative structure.
- Clear, bounded work executes directly. Clarify missing facts before changing files.
- Writing/research stays read-only unless the user also asks for an edit or implementation.

## Key detailed rules

<!-- vibeguard-generated-compact-rules:start -->
| ID | Severity | Rule |
|----|----------|------|
| U-17 | Strict | Handle errors completely. Do not swallow exceptions silently. |
| U-29 | Strict | No silent degradation: errors causing user-visible missing data or wrong output must `error` or raise, not `warning` + fallback. |
| W-02 | Strict | After 3 consecutive failed fixes on the same problem, stop and challenge the hypothesis or architecture. |
| W-03 | Strict | Verify before claiming completion: produce fresh command output proving the claim. |
| W-12 | Strict | Protect test integrity: fix production code, never weaken assertions or tamper with test infrastructure. |
| W-16 | Strict | Verification commands must come from this session. "Earlier passed" / "should work" do not count. |
| SEC-01 | Critical | No SQL / NoSQL / OS command injection: use parameterized queries and array argument lists. |
| SEC-02 | Critical | No hardcoded keys, credentials, or API tokens. Load from env / secret manager. |
| SEC-11 | Strict | AI-generated code carries higher security risk; mandatory human review for auth, payments, secrets, `innerHTML` / `eval` / `exec`. |
| SEC-13 | Strict | High-context files (`AGENTS.md`, `CLAUDE.md`, `.claude/settings*.json`, hooks) must not be silently modified by dependencies or generators. |
<!-- vibeguard-generated-compact-rules:end -->

## Codex host guidance

- Repository-level and nested `AGENTS.md` files provide project-specific facts and take precedence over these global defaults.
- VibeGuard does not install bundled Codex skills into `$CODEX_HOME/skills/`; preserve user-managed skills there and use them only when their activation conditions match the task.
- Codex hook installation follows the selected setup profile: every profile covers native Bash and `apply_patch` gates; `full` and `strict` additionally install `post-build-check` and `Stop` hooks (`stop-guard` and `learn-evaluator`). Read, Glob, and Grep hook surfaces are unavailable, so do not claim those loops were mechanically intercepted.
- Claude-only slash commands, `/clear`, native rule paths, and compaction behavior are not part of this Codex contract.
<!-- vibeguard-end -->
