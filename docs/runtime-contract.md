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

Forced `git clean` is denied when it has no pathspec or when any pathspec is bulk: `.`/empty after lexical normalization, any `..` component, absolute or `~` paths, pathspec magic (`:`), globs (`*`, `?`, `[`), or `$`, backtick and backslash characters. A clean that names only specific relative paths, such as `git clean -fd -- scratch.txt`, stays quiet. The recognizer receives no verified task-level authorization; it limits forced cleanup to named targets so an agent can carry out cleanup the user authorized for specific files. The [installation pilot's authorized-cleanup false block](../eval/2026-10-07-installation-pilot.md) used bare `git clean -fd`, which remains denied; the denial message directs the agent to preview and name the authorized paths. A dry run does not authorize a later bulk deletion.

For Codex, [`PreToolUse` does not support `permissionDecision: "ask"`](https://learn.chatgpt.com/docs/hooks#pretooluse): that response fails the hook and continues the tool call. `PermissionRequest` only handles an approval the host is already requesting; it cannot turn this denial into a per-call approval. When an already-authorized whole-tree cleanup is blocked, the agent may name the specific authorized paths or report the limitation. The user can perform the exact reviewed operation themselves in their own terminal. The agent must not substitute a command/tool or disable hooks to work around the denial. This manual user action is outside VibeGuard's hook coverage, not a completed agent task or a verified host-trust journey.

The [DSH adapter](../plugins/dsh/README.md) maps a pre-call policy denial to DSH's `ask` decision. DSH's ToolRuntime owns the approval request and records `approval/asked` and `approval/decided`; a grant applies once, and refusal, cancellation, absent approval service/channel, or an agent-less call denies dispatch. A runtime/process/protocol failure is a hard pre-call denial, never an approval request. Post-call observation failures are notices and preserve the completed tool result. DSH installation uses its profile plugin command; the Rust install/status commands target Claude, Codex, Grok and Git only.

The Bash recognizer tokenizes simple words, comments, command boundaries, and redirections while masking supported heredoc bodies. Quoted words retain their command or argument position. Newlines separate commands after supported line continuations are removed. Redirections include adjacent unquoted decimal file descriptors and operators such as `2>&1`, `>|`, and `&>`; their operands do not become command arguments. Heredoc delimiters are complete simple words after quote removal, including punctuation, and escaped `<` characters do not start a heredoc. ANSI-C (`$'...'`) and locale (`$"..."`) quoting in a heredoc delimiter are explicitly rejected: this recognizer does not evaluate their escapes or translations and must not mask later commands using a guessed terminator. Dollar/quote characters inside ordinary quoted delimiters remain literal. Only LF ends a heredoc line; a preceding CR remains part of the delimiter or body, including in CRLF input. It recognizes bulk `git checkout/restore .`, forced `git clean` without specific paths except dry-run, and selected forced recursive removal of root/home/system paths. It does not interpret arbitrary shell grammar, scripts, aliases, substitutions, variables generally, or alternate tools.

Within these simple commands, path words retain the distinction between literal text and supported HOME/tilde expansion. Git clean options are read in order, stop at `--`, and consume `-e`/`--exclude` pattern arguments, including Git's accepted long-option abbreviations such as `--excl`. A later `--no-force` or `--no-dry-run` resets its respective flag. Brace-containing pathspecs are conservatively treated as bulk, including quoted spellings, rather than evaluating shell brace expansion.

Rm recognizes recursive and force flags across clustered or split short options and mixed long options, stopping option recognition at `--`. Absolute target paths are compared after lexically collapsing repeated slashes, `.` and `..`. Supported HOME, bare tilde and unquoted `~root` prefixes recognize paths that normalize to the home directory. Paths with remaining leading `..` components are conservatively denied: they leave the symbolic home base and may descend into a protected target, such as `$HOME/../../etc`. Ordinary home subdirectories and quoted literal HOME/tilde filenames remain allowed. No filesystem lookup, user lookup or general symlink resolution occurs; on macOS, `/private/etc` and `/private/var` are explicitly protected like `/etc` and `/var`.

| Example | Recognition |
|---|---|
| `rm -rf '$HOME'`, `rm -rf '~'` | Allowed: literal relative filenames |
| `rm -rf "$HOME"`, `rm -rf '/etc'` | Denied: recognized protected targets |
| `git clean --force -d`, `git clean -fd -- -n .` | Denied: forced bulk operation; `-n` after `--` is a path |
| `git clean -fd -- scratch.txt`, `git clean -f build/` | Allowed: forced operation limited to named relative paths |
| `git clean -f -- '*.log'`, `git clean -f ../x` | Denied: glob or parent-escaping pathspec counts as bulk |
| `git clean -nfd`, `git clean -f --no-force` | Allowed: dry-run or explicit force reset |
| `git clean -f -e -n` | Denied: `-n` is an exclusion pattern |

These examples describe recognition, not a general safety guarantee. Shell substitutions, arbitrary variable expansion, aliases and scripts remain outside the supported grammar; an unrecognized spelling is not proof that an operation is safe. The existing root/home/system prefix policy is unchanged.

`pre-push` classifies updates by the remote destination ref. It rejects all ref deletions. Unchanged nonzero OIDs in any namespace are allowed without object lookup; the hook continues checking subsequent records. New `refs/tags/*` are allowed; replacing an existing tag OID is rejected, including annotated tags pointing to the same commit and tags targeting non-commit objects. Tag decisions do not require ancestry or object lookup.

Branches (`refs/heads/*`) must target commit objects directly; existing branches also require `git merge-base --is-ancestor`. Other namespaces allow new refs; existing updates retain the ancestry check after peeling tag objects to commits. Existing non-commit targets in those namespaces are explicitly rejected, rather than reported as missing objects. This is a limited local policy, not a complete implementation of Git's namespace rules. Missing required objects or Git inspection errors return exit 2; policy denials return exit 1. The hook processes all pushed refs, does not fetch, and can be bypassed with `--no-verify`; server-side ref protection remains necessary.

Object-type and ancestry inspection use `git --no-replace-objects --no-lazy-fetch`, requiring Git 2.45 or newer. Git install (including dry-run) and status check these capabilities before setup writes or reporting protection; uninstall remains available with older Git. Local `refs/replace` entries cannot substitute object types or commit ancestry for these checks, and missing promisor objects are not downloaded automatically. Each inspection also overrides `GIT_GRAFT_FILE` with the platform null device, so the repository's `info/grafts` and inherited custom graft files cannot alter the checked ancestry. Unsupported Git options produce exit 2 with the minimum-version requirement; the hook does not retry without those flags. If required objects are absent, fetch them separately before retrying the push. Git 2.45 introduced `--no-lazy-fetch`; see its [release notes](https://github.com/git/git/blob/v2.45.0/Documentation/RelNotes/2.45.0.txt).

On Windows only, the parsed Bash path word also recognizes drive-letter absolute
paths (`C:/Windows`, quoted `C:\Windows`), Git Bash drive mounts (`/c/Windows`),
and UNC server/share roots. Comparisons ignore ASCII case and normalize `.`/`..`
inside a volume before trimming trailing spaces and periods for comparison.
Intermediate all-dot/space components retain their path level during navigation;
without a trailing separator, an all-dot/space final component denotes its parent.
Drive/share roots, `Users` and immediate profile roots, `Windows`,
`Program Files`, `Program Files (x86)` and `ProgramData` are protected; ordinary
profile subdirectories remain allowed. Unquoted Bash backslashes are escape
characters, so raw Windows spellings are not interpreted as PowerShell syntax.

For forced recursive removal, local drive-letter paths and Git Bash drive mounts
also use Windows `GetFullPathNameW` and `GetLongPathNameW` before an allow decision.
The OS resolves actual short names, without guessing aliases from a tilde. Missing
descendants retain their names after resolving the longest existing parent prefix.
An inaccessible, invalid or otherwise uninspectable local path is denied with a
resolution-failure explanation. UNC checks remain lexical and perform no network
lookup: share roots and recognized long-name system/profile paths are checked,
but remote short-name aliases are not resolved. This is not full path coverage or
a race-free filesystem boundary.
This does not resolve reparse points, symlinks, mount aliases or variables.

## Observations

Installed commands supply `--state-dir`; direct use without it creates no observation. Each host retains only the latest received event, including `dsh.json` for the DSH adapter. Concurrent sessions can replace each other's last event.

Observation writes are best-effort diagnostics. If a write returns an error, the hook preserves its evaluated policy decision and exit 0, emits a user-facing `systemMessage` warning, and writes diagnostic details to stderr. It does not block an otherwise allowed call or replace a completed tool result. The warning notes that status may show an older observation; a failed write cannot establish a fresh result. Malformed protocol and policy evaluation errors still return exit 2. This does not make filesystem I/O nonblocking or provide a timeout guarantee.

Fields are timestamp, host, event, tool, tool-use ID, cwd, outcome, optional exit code. Raw commands, stdout, stderr, error strings, and prompts are not retained.

Outcomes distinguish requested, denied, exited_zero, exited_nonzero, running, interrupted, failed, and exit_status_unavailable. Only structured exit codes are recorded. Claude's normal Bash result can omit a code. Printed success and failure display strings do not become guessed exit codes.

There is no verified-tree flag. A previous result, background ID, command containing "test", or absence of observed edits cannot establish task completion.

## Installation

`install <claude|codex|grok|git> --dry-run` reuses installation input validation and content preparation, then prints JSON stdout and a human preview on stderr before acquiring locks or writing files. It lists changed paths, operations, hook commands, and the persistent locks used by a real install. Invalid inputs and a user-owned Git hook still return exit 2. Existing `disableAllHooks` settings, unrelated handlers and user guidance are preserved; the preview warns about a disabled host. `status` and `uninstall` reject `--dry-run`. Native Windows supports Claude Code installation, preview and removal; other native Windows targets remain unsupported. Windows uses HOME, falling back to USERPROFILE when HOME is missing or empty.

Preview describes current inputs; it does not establish write permissions, metadata-copy success, lock availability, host trust, or actual protection. The source `setup.sh` launcher may build Cargo artifacts before forwarding `--dry-run`; the runtime installer itself writes nothing. Installation into an absent home does not create an instruction file. An existing owned core block is removed while surrounding user text stays intact.

| Target | Configuration | Existing instructions (owned-block removal) |
|---|---|---|
| Claude | `$CLAUDE_CONFIG_DIR/settings.json`, default `~/.claude/settings.json` | Same directory's `CLAUDE.md` |
| Codex | `$CODEX_HOME/hooks.json`, default `~/.codex/hooks.json` | Same directory's `AGENTS.md` |
| Grok | `$GROK_HOME/hooks/vibeguard.json`, default `~/.grok/hooks/vibeguard.json` | Same Grok directory's existing `rules/vibeguard.md` |
| Git | Resolved `git --git-path hooks/pre-push`, honoring core.hooksPath | None |

Claude install/reinstall removes retired `skills-loader.sh` command handlers from every event in the selected settings file, including manual duplicates. Matching is limited to simple calls to `~/.vibeguard/installed/hooks/skills-loader.sh`, `~/.vibeguard/dist/current/hooks/skills-loader.sh`, or the `.vibeguard/run-hook.sh skills-loader.sh` wrapper, optionally preceded by `bash` or `sh` (including interpreter paths). Other home prefixes and quoted paths are recognized, including literal punctuation inside quotes. Same-name scripts in arbitrary paths do not establish VibeGuard ownership. Unquoted escapes, shell operators, comments, command substitutions, extra arguments and arbitrary shell programs are left alone; a filename mention in another command is not an invocation. Other handlers, group properties and pre-existing empty groups remain; only groups emptied by this removal are dropped. Dry-run lists `remove_retired_skills_loader_hooks` with `handler_count`. Status, uninstall and other host installers do not perform this cleanup. This is a specific retired-feature cleanup, not a v1 migration or filesystem sweep.

Windows Claude handlers use exec form: `command` is the installed `.exe` path,
and `args` contains `hook`, `claude`, `--state-dir` and the state path. Ownership
matching includes both `command` and `args`; another invocation of the same
binary is preserved. This requires Claude Code 2.1.139 or newer, as recorded in
its [changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21139).
Windows status explicitly limits coverage to Git Bash tool events and reports
PowerShell/cmd syntax as uncovered. The native Windows integration remains
experimental pending real Claude Code session verification. CI directly invokes
the generated exec registration; it does not establish host trust or dispatch.

Binary: `~/.vibeguard/bin/vibeguard-runtime` (`vibeguard-runtime.exe` on Windows). Observations: `~/.vibeguard/state/claude.json`, `codex.json`, and `grok.json`. Grok observations retain the real tool name. `--home PATH` uses an isolated home and ignores ambient `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`, and `GEMINI_CLI_HOME`. Nonempty relative host-directory overrides resolve against the current working directory; empty overrides use the defaults. `--repo PATH` applies only to Git. No shell profile/PATH changes.

Grok installation preserves other hook files and `config.toml`, including `compat.claude.hooks`; it does not register a Python adapter or inject default rules. Status checks its native hook file, executable bits and latest Grok observation. It does not inspect effective Grok config layers, imported Claude hooks, `allow_managed_hooks_only`, folder trust or host reload state, and cannot prove dispatch. Uninstall removes only its exact commands/current block and Grok observation, retaining the shared binary and user material.

Unrelated JSON fields/handlers are preserved semantically; formatting may change. Install and uninstall remove an existing standalone `vibeguard-core:start/end` block without injecting replacement rules or lookup instructions. They do not create an instruction file. Markdown bytes outside those markers are preserved, including CRLF and no final newline. Fenced examples are ignored. Incomplete/duplicate blocks fail before mutation. The rule catalog and `rules --core` remain available for explicit reference.

Codex installation also sets `[features].hooks = true` in the selected Codex directory's `config.toml`, preserving unrelated TOML settings and comments. Invalid TOML or a non-boolean hooks flag fails before installation writes. Uninstall leaves this shared host feature enabled for other hooks. Status reads the local feature setting (including the host's `codex_hooks` alias); absent settings use Codex's current enabled default. An explicit false setting makes status incomplete. This does not inspect higher-priority configuration or administrator requirements and cannot establish effective host permission or trust. See [Codex hooks](https://learn.chatgpt.com/docs/hooks#turn-hooks-off).

Nonregular target files, symlink targets, malformed JSON, and invalid UTF-8 are rejected. Configuration and instructions are validated before copying the binary. Individual writes are atomic; installation is not a multi-file transaction. I/O errors can leave a visible partial install: resolve the error, reinstall, and check status. Directory symlinks are not a sandbox boundary.

Install and uninstall coordinate their write phase with advisory locks at `~/.vibeguard/setup.lock` and the selected host or Git hooks directory's `.vibeguard-setup.lock`. Lock contention returns exit 2 with retry guidance. These lock files remain in place; closing the descriptors releases the locks, including after a process exits. Status does not create or acquire them. Before changing user files, setup compares their current bytes with the snapshots it validated, and rechecks immediately before atomic replacement. A detected edit returns a visible conflict instead of overwriting it; earlier writes can still have completed. Other programs do not participate in these locks, and a final comparison plus rename is not an atomic compare-and-swap with an external writer. Avoid editing host configuration concurrently with setup.

Different homes can intentionally share one `CODEX_HOME`. Sequential installs retain both homes' command handlers; the shared lock coordinates writes and does not choose a single installation. Reinstall and uninstall match only the selected home's exact generated command. Uninstalling home A leaves home B and third-party handlers in place; each home keeps its own binary and observation directory. To remove A from a shared directory, use the same `HOME` and `CODEX_HOME` environment as A's installation. Passing `--home A` instead selects the isolated `A/.codex` directory.

On macOS and Linux, replacement of an existing user file preserves its owner, group, mode, ACL, and extended attributes exposed by the operating system to the current user. Metadata is copied onto the temporary file before the atomic rename. A metadata read/copy error aborts that replacement and leaves the original file intact; it does not roll back earlier installation writes. Replacement does not retain an ACL inherited by the temporary file when the original had none. Reinstall restores all execute bits on product-owned executable files. Apart from the Claude install cleanup above, only exact managed hook commands/current blocks are removed; no general legacy migration. Git refuses a user-managed pre-push file. Uninstall retains the shared binary and unrelated configuration. Instruction files remain even when removing the managed block leaves them empty, preserving user-file metadata without tracking file ownership. Uninstall does not create an absent instruction file.

On Windows, existing targets use `ReplaceFileW` with zero flags to preserve the
target DACL. ACL/metadata merge errors are not ignored and there is no rename
fallback for failed replacement. New files retain ordinary directory inheritance.
Replacement failures return exit 2. The documented Windows errors 1176/1177 can
leave a partial replacement; for those errors the staged content is retained and
the error names its recovery path. Other failures retain the existing temporary
cleanup behavior. This does not make installation a transaction or promise that
every Windows replacement failure leaves the original path intact.

## Status and platforms

Status exit 0 means expected hook entries and required executable mode bits are present, without local `disableAllHooks: true` or a disabled Codex hooks feature. Exit 1 means incomplete/disabled state; exit 2 means inspection error. The executable fields check mode bits, not ACLs or noexec mounts.

Claude and Codex status include `installation_home`, `binary`, `state_dir`, and `hook_registrations`. Each registration reports its configured command, event, matcher, and zero-based group/handler positions in the selected configuration file. `selected_instance` is true only for an exact match to the selected home's generated command. Other rows can belong to another VibeGuard home or a third party; commands are displayed without parsing or execution, and other homes' binaries or observations are not inspected. Additional handlers produce a diagnostic, but do not change the selected installation's readiness or status exit code. Status remains read-only.

Status does not report `core_present` or validate prompt text as a readiness condition. Missing, edited or malformed core text does not make a configured hook installation incomplete; status leaves instruction files untouched. Install and uninstall still reject malformed owned markers before writes because they may remove that block.

`host_trust: "not_observed"` remains unknown even after a past call. Other configuration layers, host trust/reloading, and routes outside Bash are outside this diagnosis.

Claude, Codex and Grok status append the registered-event scope and latest received observation to the human summary on stderr. When setup is incomplete or locally disabled, the scope is explicitly labeled as potential coverage once setup is complete. With no observation, the summary says so explicitly. A record shows its Unix-millisecond timestamp, cwd, tool, event, outcome and structured exit code, or `unavailable` when no code was recorded. Record fields are JSON-escaped for display. The latest event is shared across sessions for that installation and host; it can be old or belong to another cwd. Even an exit code of zero does not prove host trust, actual execution, full protection or task completion for the current project. These diagnostics follow the existing setup and next-action messages, preserving disabled-hook and legacy-inventory warning priority. JSON stdout, status exit codes and read-only behavior are unchanged; no current-project probe or new protection state is inferred.

`legacy` is a read-only inventory attached to `status`, `install`, and `uninstall`. It does not change the status exit code. `owned` means a known v1 product path under `.vibeguard`, a VibeGuard wrapper signature, or an exact `<!-- vibeguard-start -->` / `<!-- vibeguard-end -->` region from the v1.1 installation layout. `suspected` means the same names appear without that owned form, including generic script suffixes in arbitrary checkouts, fenced examples and prose. `not_checked` means that location or the account crontab could not be read. A different `--home` reports crontab `access: not_applicable` and does not read the account crontab. Symlinks are reported and not followed. Other nonregular files are not opened, and file content reads are capped at 1 MiB plus one byte to detect overflow. Discovered commands are not executed, and crontab is not modified. `--repo` resolves the working-tree root even when given a subdirectory, then inspects root `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.claude/settings.json`, and Git `pre-commit` / `pre-push` hooks. Bare repositories receive hook inspection without working-tree instruction scans. The current v2 hook command and `# VibeGuard native pre-push hook` are current entries, not v1 findings.

Migration commands are in `legacy.migration`: v1 source `bash setup.sh --clean`, v1 release snapshot `bash ~/.vibeguard/dist/current/setup.sh --clean`, v2 source `bash setup.sh install <claude|codex>`, and v2 release archive `./vibeguard-runtime install <claude|codex>`. Deleting a v1 checkout leaves hooks and scheduler entries in place. Installing v2 leaves v1 files and other registrations in place; Claude installation has only the retired skills-loader registration exception described above.

Advisory Git inventory queries use a 2-second timeout followed by up to 2 seconds waiting for termination. A timed-out query is reported as `not_checked`; the primary install, uninstall or status result remains available. Each query has its own timeout, so multiple unavailable locations can add to the inventory's latency.

Native installation supports macOS, Linux, and WSL. Native Windows experimentally supports Claude Code with Git Bash, including install, preview, status and uninstall. Other native Windows install/uninstall targets fail without writes. Windows CI tests the portable CLI/protocol and Claude installation; real Windows Claude Code trust and dispatch remain unverified.

Verified against [Codex hooks](https://learn.chatgpt.com/docs/hooks) and [Claude Code hooks](https://code.claude.com/docs/en/hooks), accessed 2026-09-17. Grok was checked against [Grok hooks](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md) and [event serialization](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-hooks/src/event.rs), accessed 2026-10-07. Host support is broader than VibeGuard's selected shell registration.
