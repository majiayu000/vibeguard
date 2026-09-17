# Runtime contract

One local Rust executable handles hooks, rules, and installation. It does not run an agent loop, proxy a model API, execute proposed Bash commands, or select project checks.

## Protocol

`hook claude` and `hook codex` consume one JSON object on stdin, capped at 4 MiB. Required fields are event name, nonempty cwd, tool name `Bash`, and `tool_input.command`. Malformed input/unsupported events return exit 2; payload contents are not echoed.

| Event | Claude | Codex | Behavior |
|---|---|---|---|
| PreToolUse / Bash | Yes | Yes | Native `hookSpecificOutput.permissionDecision: "deny"` for recognized forbidden spelling; otherwise quiet |
| PostToolUse / Bash | Yes | Yes | Optional latest outcome observation |
| PostToolUseFailure / Bash | Yes | No | Failed/interrupted observation; Claude error field required |

Policy denial uses native JSON with exit 0. Exit 2 denotes runtime/protocol error; host error handling is not a universal fail-closed guarantee. No `ask` decision is emitted. No Stop, Read, search, apply_patch, Edit, MCP, or hosted-tool hooks are registered.

The Bash recognizer masks comments, quoted data, and supported heredoc bodies. It recognizes bulk `git checkout/restore .`, forced `git clean` except dry-run, and selected forced recursive removal of root/home/system paths. It does not interpret arbitrary shell grammar, scripts, aliases, substitutions, variables generally, or alternate tools.

`pre-push` consumes Git ref updates and checks `git merge-base --is-ancestor`. It rejects deletions/non-fast-forward updates, allows new refs, and errors on unavailable objects. It covers all pushed refs, does not fetch, and cannot prevent `--no-verify`.

## Observations

Installed commands supply `--state-dir`; direct use without it creates no observation. Each host retains only the latest received event. Concurrent sessions can replace each other's last event.

Fields are timestamp, host, event, tool, tool-use ID, cwd, outcome, optional exit code. Raw commands, stdout, stderr, error strings, and prompts are not retained.

Outcomes distinguish requested, denied, exited_zero, exited_nonzero, running, interrupted, failed, and exit_status_unavailable. Only structured exit codes are recorded. Claude's normal Bash result can omit a code. Printed success and failure display strings do not become guessed exit codes.

There is no verified-tree flag. A previous result, background ID, command containing "test", or absence of observed edits cannot establish task completion.

## Installation

| Target | Configuration | Instructions |
|---|---|---|
| Claude | `~/.claude/settings.json` | `~/.claude/CLAUDE.md` |
| Codex | `$CODEX_HOME/hooks.json`, default `~/.codex/hooks.json` | Same directory's `AGENTS.md` |
| Git | Resolved `git --git-path hooks/pre-push`, honoring core.hooksPath | None |

Binary: `~/.vibeguard/bin/vibeguard-runtime`. Observations: `~/.vibeguard/state/claude.json` and `codex.json`. `--home PATH` uses an isolated home and ignores ambient `CODEX_HOME`. `--repo PATH` applies only to Git. No shell profile/PATH changes.

Unrelated JSON fields/handlers are preserved semantically; formatting may change. Markdown bytes outside standalone `vibeguard-core:start/end` markers are preserved, including CRLF and no final newline. Fenced examples are ignored. Incomplete/duplicate blocks fail before mutation.

Nonregular target files, symlink targets, malformed JSON, and invalid UTF-8 are rejected. Configuration and instructions are validated before copying the binary. Individual writes are atomic; installation is not a multi-file transaction. I/O errors can leave a visible partial install: resolve the error, reinstall, and check status. Directory symlinks are not a sandbox boundary.

User-file permissions remain intact. Reinstall restores all execute bits on product-owned executable files. Only exact managed hook commands/current blocks are removed; no legacy migration. Git refuses a user-managed pre-push file. Uninstall retains the shared binary and unrelated configuration.

## Status and platforms

Status exit 0 means expected entries, core, and required executable mode bits are present, without local `disableAllHooks: true`. Exit 1 means incomplete/disabled state; exit 2 means inspection error. The executable fields check mode bits, not ACLs or noexec mounts.

`host_trust: "not_observed"` remains unknown even after a past call. Other configuration layers, host trust/reloading, and routes outside Bash are outside this diagnosis.

Native installation supports macOS, Linux, and WSL. Windows install/uninstall errors without writes; portable CLI/protocol tests run in Windows CI.

Verified against [Codex hooks](https://learn.chatgpt.com/docs/hooks) and [Claude Code hooks](https://code.claude.com/docs/en/hooks), accessed 2026-09-17. Host support is broader than VibeGuard's selected Bash registration.
