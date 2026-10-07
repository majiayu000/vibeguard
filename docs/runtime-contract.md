# Runtime contract

One local Rust executable handles hooks, rules, and installation. It does not run an agent loop, proxy a model API, execute proposed Bash commands, or select project checks.

## Protocol

`hook claude`, `hook codex`, `hook grok`, and `hook dsh` consume one JSON object on stdin, capped at 4 MiB. Claude/Codex/DSH required fields are event name, nonempty cwd, tool name `Bash`, and `tool_input.command`. Malformed input/unsupported events return exit 2; payload contents are not echoed. DSH accepts PreToolUse/PostToolUse and records its own `dsh` host attribution; the npm adapter translates DSH tool values to this protocol.

Grok accepts `run_terminal_command` (and its matcher spelling `Bash`), native `hookEventName` values `pre_tool_use`, `post_tool_use`, `post_tool_use_failure`, and the documented Claude-style aliases. `toolName`, `toolInput`, `toolResult`, `toolUseId`, and `isInterrupt` map to the corresponding common fields; native camelCase values take precedence. Only `toolInput.command` is evaluated; no `cmd`/`script` guesses or other shell tools are accepted. Pre-use input marked `toolInputTruncated: true` is an error. Post-use input may be truncated because it is not evaluated. A string/truncated result has no inferred exit code; `isBackgrounded: true` records `running` without a completed exit code. Failure events require `error` and honor `isInterrupt`.

When Grok imports the Claude registration, `hook claude` recognizes its native envelope or `run_terminal_command` tool name and uses the Grok protocol and observation file. `hook codex` remains strict. Grok accepts the same native `hookSpecificOutput.permissionDecision` deny output with exit 0. Grok also treats pre-use exit 2 as denial, but arbitrary hook failures/timeouts can fail open; protocol errors are not a universal protection guarantee. Both registrations may run when Claude compatibility is enabled; each evaluates the same policy, and observations retain only the last event.

| Event | Claude | Codex | Behavior |
|---|---|---|---|
| PreToolUse / Bash | Yes | Yes | Native `hookSpecificOutput.permissionDecision: "deny"` for recognized forbidden spelling; otherwise quiet |
| PostToolUse / Bash | Yes | Yes | Optional latest outcome observation |
| PostToolUseFailure / Bash | Yes | No | Failed/interrupted observation; Claude error field required |

Grok registers the same three events for `run_terminal_command`. These selected shell checks do not add hooks for every tool or lifecycle event.

Policy denial uses native JSON with exit 0. Exit 2 denotes runtime/protocol error; host error handling is not a universal fail-closed guarantee. No `ask` decision is emitted. No Stop, Read, search, apply_patch, Edit, MCP, or hosted-tool hooks are registered.

The [DSH adapter](../plugins/dsh/README.md) maps a pre-call policy denial to DSH's `ask` decision. DSH's ToolRuntime owns the approval request and records `approval/asked` and `approval/decided`; a grant applies once, and refusal, cancellation, absent approval service/channel, or an agent-less call denies dispatch. A runtime/process/protocol failure is a hard pre-call denial, never an approval request. Post-call observation failures are notices and preserve the completed tool result. DSH installation uses its profile plugin command; the Rust install/status commands target Claude, Codex, Grok and Git only.

The Bash recognizer tokenizes simple words, comments, command boundaries, and redirections while masking supported heredoc bodies. Quoted words retain their command or argument position. Newlines separate commands after supported line continuations are removed. Redirections include adjacent unquoted decimal file descriptors and operators such as `2>&1`, `>|`, and `&>`; their operands do not become command arguments. Heredoc delimiters are complete simple words after quote removal, including punctuation, and escaped `<` characters do not start a heredoc. Only LF ends a heredoc line; a preceding CR remains part of the delimiter or body, including in CRLF input. It recognizes bulk `git checkout/restore .`, forced `git clean` except dry-run, and selected forced recursive removal of root/home/system paths. It does not interpret arbitrary shell grammar, scripts, aliases, substitutions, variables generally, or alternate tools.

Within these simple commands, path words retain the distinction between literal text and supported HOME/tilde expansion. Git clean options are read in order, stop at `--`, and consume `-e`/`--exclude` pattern arguments. A later `--no-force` or `--no-dry-run` resets its respective flag.

Rm recognizes recursive and force flags across clustered or split short options and mixed long options, stopping option recognition at `--`. Absolute target paths are compared after lexically collapsing repeated slashes, `.` and `..`. Supported HOME, bare tilde and unquoted `~root` prefixes recognize paths that normalize to the home directory. Paths with remaining leading `..` components are conservatively denied: they leave the symbolic home base and may descend into a protected target, such as `$HOME/../../etc`. Ordinary home subdirectories and quoted literal HOME/tilde filenames remain allowed. No filesystem lookup, user lookup or general symlink resolution occurs; on macOS, `/private/etc` and `/private/var` are explicitly protected like `/etc` and `/var`.

| Example | Recognition |
|---|---|
| `rm -rf '$HOME'`, `rm -rf '~'` | Allowed: literal relative filenames |
| `rm -rf "$HOME"`, `rm -rf '/etc'` | Denied: recognized protected targets |
| `git clean --force -d`, `git clean -fd -- -n` | Denied: forced operation; `-n` after `--` is a path |
| `git clean -nfd`, `git clean -f --no-force` | Allowed: dry-run or explicit force reset |
| `git clean -f -e -n` | Denied: `-n` is an exclusion pattern |

These examples describe recognition, not a general safety guarantee. Shell substitutions, arbitrary variable expansion, aliases and scripts remain outside the supported grammar; an unrecognized spelling is not proof that an operation is safe. The existing root/home/system prefix policy is unchanged.

`pre-push` classifies updates by the remote destination ref. It rejects all ref deletions. Unchanged nonzero OIDs in any namespace are allowed without object lookup; the hook continues checking subsequent records. New `refs/tags/*` are allowed; replacing an existing tag OID is rejected, including annotated tags pointing to the same commit and tags targeting non-commit objects. Tag decisions do not require ancestry or object lookup.

Branches (`refs/heads/*`) must target commit objects directly; existing branches also require `git merge-base --is-ancestor`. Other namespaces allow new refs; existing updates retain the ancestry check after peeling tag objects to commits. Existing non-commit targets in those namespaces are explicitly rejected, rather than reported as missing objects. This is a limited local policy, not a complete implementation of Git's namespace rules. Missing required objects or Git inspection errors return exit 2; policy denials return exit 1. The hook processes all pushed refs, does not fetch, and can be bypassed with `--no-verify`; server-side ref protection remains necessary.

## Observations

Installed commands supply `--state-dir`; direct use without it creates no observation. Each host retains only the latest received event, including `dsh.json` for the DSH adapter. Concurrent sessions can replace each other's last event.

Observation writes are best-effort diagnostics. If a write returns an error, the hook preserves its evaluated policy decision and exit 0, emits a user-facing `systemMessage` warning, and writes diagnostic details to stderr. It does not block an otherwise allowed call or replace a completed tool result. The warning notes that status may show an older observation; a failed write cannot establish a fresh result. Malformed protocol and policy evaluation errors still return exit 2. This does not make filesystem I/O nonblocking or provide a timeout guarantee.

Fields are timestamp, host, event, tool, tool-use ID, cwd, outcome, optional exit code. Raw commands, stdout, stderr, error strings, and prompts are not retained.

Outcomes distinguish requested, denied, exited_zero, exited_nonzero, running, interrupted, failed, and exit_status_unavailable. Only structured exit codes are recorded. Claude's normal Bash result can omit a code. Printed success and failure display strings do not become guessed exit codes.

There is no verified-tree flag. A previous result, background ID, command containing "test", or absence of observed edits cannot establish task completion.

## Installation

| Target | Configuration | Existing instructions (owned-block removal) |
|---|---|---|
| Claude | `$CLAUDE_CONFIG_DIR/settings.json`, default `~/.claude/settings.json` | Same directory's `CLAUDE.md` |
| Codex | `$CODEX_HOME/hooks.json`, default `~/.codex/hooks.json` | Same directory's `AGENTS.md` |
| Grok | `$GROK_HOME/hooks/vibeguard.json`, default `~/.grok/hooks/vibeguard.json` | Same Grok directory's existing `rules/vibeguard.md` |
| Git | Resolved `git --git-path hooks/pre-push`, honoring core.hooksPath | None |

Binary: `~/.vibeguard/bin/vibeguard-runtime`. Observations: `~/.vibeguard/state/claude.json`, `codex.json`, and `grok.json`. Grok observations retain the real tool name. `--home PATH` uses an isolated home and ignores ambient `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`, and `GEMINI_CLI_HOME`. Nonempty relative host-directory overrides resolve against the current working directory; empty overrides use the defaults. `--repo PATH` applies only to Git. No shell profile/PATH changes.

Grok installation preserves other hook files and `config.toml`, including `compat.claude.hooks`; it does not register a Python adapter or inject default rules. Status checks its native hook file, executable bits and latest Grok observation. It does not inspect effective Grok config layers, imported Claude hooks, `allow_managed_hooks_only`, folder trust or host reload state, and cannot prove dispatch. Uninstall removes only its exact commands/current block and Grok observation, retaining the shared binary and user material.

Unrelated JSON fields/handlers are preserved semantically; formatting may change. Install and uninstall remove an existing standalone `vibeguard-core:start/end` block without injecting replacement rules or lookup instructions. They do not create an instruction file. Markdown bytes outside those markers are preserved, including CRLF and no final newline. Fenced examples are ignored. Incomplete/duplicate blocks fail before mutation. The rule catalog and `rules --core` remain available for explicit reference.

Codex installation also sets `[features].hooks = true` in the selected Codex directory's `config.toml`, preserving unrelated TOML settings and comments. Invalid TOML or a non-boolean hooks flag fails before installation writes. Uninstall leaves this shared host feature enabled for other hooks. Status reads the local feature setting (including the host's `codex_hooks` alias); absent settings use Codex's current enabled default. An explicit false setting makes status incomplete. This does not inspect higher-priority configuration or administrator requirements and cannot establish effective host permission or trust. See [Codex hooks](https://learn.chatgpt.com/docs/hooks#turn-hooks-off).

Nonregular target files, symlink targets, malformed JSON, and invalid UTF-8 are rejected. Configuration and instructions are validated before copying the binary. Individual writes are atomic; installation is not a multi-file transaction. I/O errors can leave a visible partial install: resolve the error, reinstall, and check status. Directory symlinks are not a sandbox boundary.

On macOS and Linux, replacement of an existing user file preserves its owner, group, mode, ACL, and extended attributes exposed by the operating system to the current user. Metadata is copied onto the temporary file before the atomic rename. A metadata read/copy error aborts that replacement and leaves the original file intact; it does not roll back earlier installation writes. Replacement does not retain an ACL inherited by the temporary file when the original had none. Reinstall restores all execute bits on product-owned executable files. Only exact managed hook commands/current blocks are removed; no legacy migration. Git refuses a user-managed pre-push file. Uninstall retains the shared binary and unrelated configuration. Instruction files remain even when removing the managed block leaves them empty, preserving user-file metadata without tracking file ownership. Uninstall does not create an absent instruction file.

## Status and platforms

Status exit 0 means expected hook entries and required executable mode bits are present, without local `disableAllHooks: true` or a disabled Codex hooks feature. Exit 1 means incomplete/disabled state; exit 2 means inspection error. The executable fields check mode bits, not ACLs or noexec mounts.

Status does not report `core_present` or validate prompt text as a readiness condition. Missing, edited or malformed core text does not make a configured hook installation incomplete; status leaves instruction files untouched. Install and uninstall still reject malformed owned markers before writes because they may remove that block.

`host_trust: "not_observed"` remains unknown even after a past call. Other configuration layers, host trust/reloading, and routes outside Bash are outside this diagnosis.

`legacy` is a read-only inventory attached to `status`, `install`, and `uninstall`. It does not change the status exit code. `owned` means a known v1 path or exact `<!-- vibeguard-start -->` / `<!-- vibeguard-end -->` region from the v1.1 installation layout. `suspected` means the same names appear without that owned form, including fenced examples and prose. `not_checked` means that location or the account crontab could not be read. A different `--home` reports crontab `access: not_applicable` and does not read the account crontab. Symlinks are reported and not followed. Discovered commands are not executed, and crontab is not modified. `--repo` inspects that repository's root `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.claude/settings.json`, and Git `pre-commit` / `pre-push` hooks. The current v2 hook command and `# VibeGuard native pre-push hook` are current entries, not v1 findings.

Migration commands are in `legacy.migration`: v1 source `bash setup.sh --clean`, v1 release snapshot `bash ~/.vibeguard/dist/current/setup.sh --clean`, v2 source `bash setup.sh install <claude|codex>`, and v2 release archive `./vibeguard-runtime install <claude|codex>`. Deleting a v1 checkout leaves hooks and scheduler entries in place. Installing v2 leaves v1 material in place.

Native installation supports macOS, Linux, and WSL. Windows install/uninstall errors without writes; portable CLI/protocol tests run in Windows CI.

Verified against [Codex hooks](https://learn.chatgpt.com/docs/hooks) and [Claude Code hooks](https://code.claude.com/docs/en/hooks), accessed 2026-09-17. Grok was checked against [Grok hooks](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md) and [event serialization](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-hooks/src/event.rs), accessed 2026-10-07. Host support is broader than VibeGuard's selected shell registration.
