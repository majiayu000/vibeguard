# hooks/ directory

AI coded agent hooks script, automatically triggered before and after the operation. Both Claude Code and Codex CLI are supported.

## File description

| Documentation | Trigger Timing | Responsibilities | Codex |
|------|----------|------|-------|
| `log.sh` | Used by other hook sources | Log module, providing shared functions such as `vg_log`, JSON parsing, source code judgment, etc. | — |
| `circuit-breaker.sh` | Checked by other hook source | Circuit breaker library: CLOSED→OPEN→HALF-OPEN state machine, CI guard, stop_hook_active | — |
| `run-hook-codex.sh` | Codex wrapper | Codex output format adapter (`decision:block` → `permissionDecision:deny`) | — |
| `pre-bash-guard.sh` | PreToolUse(Bash) | Intercept dangerous commands: force push, rm -rf /, reset --hard, etc. | ✅ |
| `pre-edit-guard.sh` | PreToolUse(Edit) | Block editing of non-existent files (anti-hallucination) | ❌ |
| `pre-write-guard.sh` | PreToolUse(Write) | Remind you to search for existing implementation before creating a new source code file | ❌ |
| `post-edit-guard.sh` | PostToolUse(Edit) | Detect quality problems after editing: unwrap, console.log, hard-coded path, Go error discard, oversized diff, repeated editing of the same file (churn) | ❌ |
| `post-write-guard.sh` | PostToolUse(Write) | Detect duplicate definitions and files with the same name after creating a new file | ❌ |
| `post-build-check.sh` | PostToolUse(Edit/Write) | Automatically run the build check corresponding to the language after editing | ✅ |
| `skills-loader.sh` | Manual optional | Optional first read prompt script; not registered to hooks by default | ❌ |
| `stop-guard.sh` | Stop | Verify access control before completion and check for uncommitted source code changes | ✅ |
| `learn-evaluator.sh` | Stop | Collect metrics at the end of session + detect corrective signals (high warn rate, file churn, escalate), suggest /learn when there are signals | ✅ |
| `pre-commit-guard.sh` | git pre-commit | Automatic guard before submission: quality check + build check, 10s timeout hard limit | — |

**Codex column description**: ✅ = Deployed to `~/.codex/hooks.json`, ❌ = Codex does not support this matcher yet, — = Not applicable

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
- Codex CLI: hooks are registered in `hooks.json`, distributed through `run-hook-codex.sh` and adapted to the output format
- Both share the same hook script snapshot (`~/.vibeguard/installed/hooks/`)

## Decision type

Hooks are logged to events.jsonl using the following decision types:
`pass` / `warn` / `block` / `gate` / `escalate` / `correction` / `complete`

## Development specifications

- All hooks must introduce shared functions in `source log.sh`
- Use `vg_log` to record events instead of writing to files directly
- Pass data to python3 through environment variables to avoid injection risks
- When adding a hook, synchronously check whether it can be deployed to Codex (see matcher support)
