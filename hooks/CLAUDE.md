# hooks/ directory

AI coded agent hooks script, automatically triggered before and after the operation. Both Claude Code and Codex CLI are supported.

## File description

<!-- hooks-manifest-table:start -->
| Documentation | Trigger Timing | Responsibilities | Codex |
|------|----------|------|-------|
| `log.sh` | Used by other hook sources | Log module, providing shared functions such as vg_log, JSON parsing, source code judgment, etc. | - |
| `circuit-breaker.sh` | Checked by other hook sources | Circuit breaker library: CLOSED to OPEN to HALF-OPEN state machine, CI guard, stop_hook_active. | - |
| `run-hook-codex.sh` | Codex wrapper | Codex output format adapter (decision:block to permissionDecision:deny). | - |
| `pre-bash-guard.sh` | PreToolUse(Bash) | Intercept destructive local cleanup commands: dangerous rm -rf paths, git clean -f, and batch git checkout/restore .; force-push protection lives in the git pre-push hook. | native |
| `pre-edit-guard.sh` | PreToolUse(Edit) | Block editing of non-existent files (anti-hallucination). | native |
| `pre-write-guard.sh` | PreToolUse(Write) | Remind you to search for existing implementation before creating a new source code file. | native |
| `post-edit-guard.sh` | PostToolUse(Edit) | Detect quality problems after editing: unwrap, console.log, hard-coded path, Go error discard, oversized diff, repeated editing of the same file (churn), W-15 consecutive same-file edit loop. | native |
| `post-write-guard.sh` | PostToolUse(Write) | Detect duplicate definitions and files with the same name after creating a new file. | native |
| `analysis-paralysis-guard.sh` | PostToolUse(Read|Glob|Grep) | Detect excessive exploration without progress and prompt the agent to act. | unsupported |
| `count_active_constraints.sh` | SessionStart | Count effective task constraints loaded into agent context; warn over the U-32 budget in core/full profiles and hard-block in strict profile. | unsupported |
| `post-build-check.sh` | PostToolUse(Edit/Write) | Automatically run the build check corresponding to the language after editing. | native |
| `skills-loader.sh` | Manual optional | Optional first read prompt script; not registered to hooks by default. | unsupported |
| `stop-guard.sh` | Stop | Record uncommitted source code changes as a non-blocking Stop signal. | native |
| `learn-evaluator.sh` | Stop | Collect metrics at the end of session, detect corrective signals, and suggest /learn when signals exist. | native |
| `pre-commit-guard.sh` | git pre-commit | Automatic guard before submission: U-16 staged baseline, quality check plus build check, timeout hard limit. | - |
| `git/pre-push` | git pre-push | Block non-fast-forward pushes, remote branch deletion, and force-like push options by default. | - |
<!-- hooks-manifest-table:end -->

**Codex column description**: `native` = deployed to `~/.codex/hooks.json`, `unsupported` = Codex does not expose the required native event/tool surface, `-` = not applicable.

Codex entries use namespaced hook script names (`vibeguard-*.sh`) and are resolved by `run-hook-codex.sh` to the actual local script files.

## Dual platform deployment architecture

```
Claude Code                          Codex CLI
~/.claude/settings.json              ~/.codex/hooks.json
  ↓                                    ↓
run-hook.sh (wrapper) run-hook-codex.sh (wrapper + format adaptation)
  ↓                                    ↓
~/.vibeguard/installed/hooks/* ~/.vibeguard/installed/hooks/* (shared)
```

- Claude Code: hooks are registered in `settings.json` and distributed through `run-hook.sh`
- Codex CLI: hooks are registered in `hooks.json`, distributed through `run-hook-codex.sh`, normalized for apply_patch payloads, and adapted to the output format
- Both share the same hook script snapshot (`~/.vibeguard/installed/hooks/`)

## Decision type

Hooks are logged to events.jsonl using the following decision types:
`pass` / `warn` / `block` / `gate` / `escalate` / `correction` / `complete`

Each event keeps the backward-compatible `cli` / `agent` fields and may include
caller identity fields: `client`, `client_variant`, `wrapper`,
`source_config`, `hook_protocol_version`, and `caller_evidence`. Unknown or
manual callers must be recorded as `client: "unknown"` instead of being
silently attributed to Claude or Codex.

## Development specifications

- All hooks must introduce shared functions in `source log.sh`
- Use `vg_log` to record events instead of writing to files directly
- Configured hook production paths must stay Python-free. Use `vibeguard-runtime`
  for structured parsing, policy, and adapter logic; Python helpers are allowed
  only for tests, CI, eval, install-support tooling, or deprecated compatibility
  artifacts that are not called by configured hooks.
- When adding a hook, synchronously check whether it can be deployed to Codex (see matcher support)
