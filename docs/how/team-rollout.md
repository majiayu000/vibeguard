# Team Rollout

Use this path when VibeGuard needs to become a shared project or team policy,
not just a local experiment.

## Rollout Order

1. Install locally and complete the [Quickstart](quickstart.md).
2. Bootstrap one low-risk repository with `scripts/project-init.sh`.
3. Set a repository `.vibeguard.json` profile and run VibeGuard in `minimal`
   or `core` until warnings are understood.
4. Add `verify-install` and repository contract checks to CI.
5. Move selected repositories to `full` or `strict` only after the team accepts
   the hook behavior and false-positive handling path.

Do not automate scheduled cleanup or strict blocking until the manual path has
been validated on real team work.

## Profiles

```bash
bash ~/vibeguard/setup.sh --profile minimal
bash ~/vibeguard/setup.sh --profile core
bash ~/vibeguard/setup.sh --profile full
bash ~/vibeguard/setup.sh --profile strict
```

| Profile | Use Case |
|---------|----------|
| `minimal` | Critical pre-action interception with the smallest hook surface |
| `core` | Default local development profile |
| `full` | Adds stop/build/learning feedback for teams ready to review more signals |
| `strict` | Maximum enforcement, including stricter Claude Code constraint budget checks |

The setup commands configure the local install profile. For per-repository
runtime policy, add `.vibeguard.json` to the target repository:

```json
{
  "profile": "core",
  "enforcement": "block"
}
```

Use `minimal` for early pilots and move to `core`, `full`, or `strict` after
the team has accepted the hook surface. Without a repository config, native
Codex hooks still exist at the installed hook surface and no repository-scoped
profile narrowing is applied.

Use language selection only when a developer wants to filter the local Claude
native rule install for their machine:

```bash
bash ~/vibeguard/setup.sh --profile full --languages rust,typescript
```

This is a global local-install setting, not a repository policy. It updates the
rules linked under `~/.claude/rules/vibeguard` and does not narrow the installed
guard script tree. Prefer `.vibeguard.json` for repository-scoped profile and
enforcement policy.

## CI and Verification

Use `verify-install` for install health:

```bash
bash ~/vibeguard/setup.sh verify-install
```

Use the repository contract gate before pushing changes to VibeGuard itself:

```bash
bash scripts/local-contract-check.sh
```

For documentation-only changes in this repository, keep path references green:

```bash
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```

For manifest or routing changes, use the focused contract checks listed in
[CONTRIBUTING.md](../../CONTRIBUTING.md).

## Repository Bootstrap

```bash
bash ~/vibeguard/scripts/project-init.sh /path/to/project
```

`project-init.sh` prints project guidance and attaches the shared
pre-commit/pre-push wrappers when they are available. When it prints a
`Suggested project CLAUDE.md snippet`, save that snippet into the repository's
`CLAUDE.md`, `AGENTS.md`, or equivalent project guidance file as a manual
rollout step. Keep repository-specific facts in that repository's guidance
file; do not put local machine facts in shared VibeGuard docs.

## Codex and Claude Boundaries

Claude Code receives native rules, skills, commands, hooks, and git hooks.
Codex receives `~/.codex/AGENTS.md`, copied skills, native
Bash/apply_patch/PermissionRequest/PostToolUse/Stop hooks, and
`~/.vibeguard/run-hook-codex.sh`.

Current Codex boundary: native Read/Glob/Grep hooks are not available through
Codex, so read-only exploration gates remain Claude Code or optional
app-server-wrapper only.

## Scheduler

Scheduled GC is opt-in:

```bash
bash ~/vibeguard/setup.sh --with-scheduler
```

Treat scheduler rollout as a later stage. The manual cleanup/check path should
be stable first, and the owner should know how to disable or inspect scheduled
state before enabling it across a team.

## Observability

```bash
bash ~/vibeguard/scripts/stats.sh
bash ~/vibeguard/scripts/hook-health.sh 24
~/.vibeguard/installed/bin/vibeguard-runtime hook-status --mode focused
```

Use [Observability Harness Contract](../reference/observability-harness.md) for
metric semantics and [Hook Latency Contract](../reference/hook-latency-contract.md)
for per-hook latency budgets.
