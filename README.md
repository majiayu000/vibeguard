# VibeGuard

A Rust CLI for native coding-agent hooks and installation diagnostics.

Upgrading Claude Code from v1? Preview `vibeguard-runtime install claude --migrate-v1-hooks --dry-run`, then repeat without `--dry-run`. This backs up settings, removes recognized old hook calls (including duplicates), and installs v2 hooks while preserving unrelated integrations. Other v1 remnants still require the legacy inventory. See [installation details](docs/runtime-contract.md#installation).

[Website](https://majiayu000.github.io/vibeguard/) · [中文](docs/README_CN.md) · [Runtime contract](docs/runtime-contract.md) · [Contributing](CONTRIBUTING.md)

VibeGuard does two jobs. Native Bash hooks reject a small set of destructive command spellings and record the latest observed outcome. [The 800-line limit](#the-800-line-limit) keeps source files from growing past 800 lines: new files stay under it, and existing large files can shrink but not grow. An optional Git pre-push hook checks actual commit ancestry. The host owns permissions, sandboxing, tool execution, and the agent loop.

DeepSeek Harness users can load the [DSH Bash adapter](plugins/dsh/README.md). It calls this Rust runtime, routes policy blocks through DSH's native approval, and fails closed when the pre-call runtime fails.

## Install from a release archive

One command downloads the latest release for your OS and CPU, verifies it against `SHA256SUMS`, and runs `install`. It needs only `curl`, `tar` and `shasum` or `sha256sum`; no Rust toolchain or Python:

```bash
curl -fsSL https://raw.githubusercontent.com/majiayu000/vibeguard/main/install.sh | bash -s -- claude --dry-run
curl -fsSL https://raw.githubusercontent.com/majiayu000/vibeguard/main/install.sh | bash -s -- claude
```

Replace `claude` with `codex` or `grok`. Set `VIBEGUARD_VERSION=v2.3.0` before `bash` to pin a release. To do the same steps by hand:

Download the archive for your OS and CPU from [Releases](https://github.com/majiayu000/vibeguard/releases), extract it, and open a terminal in the extracted directory. macOS, Linux and WSL are supported; choose a Linux archive for WSL. No Rust toolchain or source checkout is required for this path. Run:

```bash
./vibeguard-runtime install codex --dry-run
./vibeguard-runtime install codex
# Or select Claude Code:
./vibeguard-runtime install claude
# Or select Grok:
./vibeguard-runtime install grok
```

### Native Windows (experimental, Claude Code + Git Bash)

Use Windows x64, Git Bash, and Claude Code **2.1.139 or later**. Exec-form
hooks were introduced in [Claude Code 2.1.139](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21139).
Download `vibeguard-x86_64-pc-windows-msvc.tar.gz` from Releases, extract it,
and run in PowerShell:

```powershell
.\install.ps1 -DryRun
.\install.ps1
& "$env:USERPROFILE/.vibeguard/bin/vibeguard-runtime.exe" status claude
```

Or download [install.ps1](install.ps1) alone and run it with the same commands.
Without an adjacent executable it downloads the latest Windows release and
checks its archive against that release's `SHA256SUMS`; `-Version vX.Y.Z`
selects a particular release. If the selected release has no Windows archive,
installation fails. `-HomeDirectory PATH` selects an isolated home. Preview
can download/extract into a temporary directory but does not write installation
files. Windows PowerShell 5.1 or PowerShell 7 and `tar.exe` are required.

The installer registers an `.exe` path plus `args` directly, with no shell
quoting. Only Claude Code's **Bash** tool is covered; PowerShell and cmd command
syntax, and native Windows Codex/Grok/Git installation, are outside this phase.
Windows paths include drive roots, user-profile roots and system directories,
using drive-letter, Git Bash `/c/...`, or UNC spelling. Backslashes must survive
Bash parsing, for example `rm -rf 'C:\Users\name'`.

Windows CI exercises installation, exact configured hook invocation and removal.
This is experimental until a real Windows Claude Code session verifies dispatch:
restart Claude Code, review `/hooks`, run a harmless Bash command, and check
`status claude` for its observation. Neither a direct hook test nor status proves
that the host trusts and dispatches hooks. Use the installed `.exe` with
`uninstall claude` to remove this integration.

The archive contains the executable, this README and LICENSE. `install --dry-run` validates current inputs and shows planned file changes, hook commands and persistent setup locks without writing files. It preserves unrelated handlers and user guidance; a disabled host remains disabled. Preview does not prove write access or active protection. Installation copies the executable to `~/.vibeguard/bin/vibeguard-runtime`. Restart the selected host and review its native hook trust settings. Check or remove that integration with:

```bash
~/.vibeguard/bin/vibeguard-runtime status codex
~/.vibeguard/bin/vibeguard-runtime uninstall codex
```

Use `claude` or `grok` instead of `codex` for those hosts. Uninstall retains the shared executable. Earlier release assets follow their own version's instructions.

## Build and install from source

Source builds require Git and the Rust toolchain pinned in `rust-toolchain.toml`. Native installation supports macOS, Linux, and WSL. Native Windows installation supports Claude Code with Git Bash experimentally; native Windows Codex, Grok and Git hook installation remains unsupported. Windows CI tests the portable CLI, JSON protocol and Claude installation.

```bash
git clone https://github.com/majiayu000/vibeguard.git
cd vibeguard
bash setup.sh --help
bash setup.sh install codex --dry-run
bash setup.sh install codex
# Or select Claude Code:
bash setup.sh install claude
# Or select Grok:
bash setup.sh install grok
```

`setup.sh` builds the checked-out source and forwards arguments. Without `cargo` it stops and points to `install.sh`, which installs the prebuilt release from the checkout. Without arguments it prints help; it does not install automatically. Install copies the binary to `~/.vibeguard/bin/vibeguard-runtime` and registers the selected integration. Installation removes an existing owned `vibeguard-core` block while preserving surrounding user instructions; it does not create an instruction file. Restart the host and review its native hook trust settings.

```bash
~/.vibeguard/bin/vibeguard-runtime status codex
~/.vibeguard/bin/vibeguard-runtime uninstall codex
```

Keep personal preferences in native host instructions, and project facts in repository instructions. Reuse relevant guidance already in the current context or handoff summary; consult its source again when details are missing, the source has changed, or inspection is requested. A separate contract file need not be read at every follow-up. VibeGuard does not rewrite surrounding user-owned guidance.

Grok installation writes `$GROK_HOME/hooks/vibeguard.json` (default `~/.grok`). It supports native shell pre-use, result and failure events without creating default instruction files. Grok's imported Claude hooks also work with the updated shared binary; observations go to `grok.json`, not `claude.json`. No Python adapter or change to `compat.claude.hooks` is required. Both registrations may evaluate a Grok event when installed together; each uses the same policy and latest observation. Status checks the native registration, not imported hooks or effective managed policy. See the [protocol contract](docs/runtime-contract.md).

Git protection is explicit: `~/.vibeguard/bin/vibeguard-runtime install git --repo /absolute/path/to/repository`. It refuses to replace a user-managed pre-push hook. Use `status git` or `uninstall git` with the same `--repo`.

## The 800-line limit

A source file (`.rs`, `.py`, `.ts`, `.go`, `.swift` and similar) may not end above 800 lines and longer than it was. Docs, data and markup are not counted. Agents write files in several ways, so the rule is applied at three points:

| When | What it sees | Hosts | What happens | How to get it |
|---|---|---|---|---|
| Before an edit | `Write`, `Edit`, `MultiEdit` | Claude Code | The edit is refused | `install claude` |
| After a Bash call | Files the repository shows as changed | Claude Code, Codex | The Agent is told; nothing is blocked | `install claude`, `install codex` |
| At commit | Staged content, however it was written | Anything that commits | The commit is refused | `install git-size`, once for the whole machine |

Only the commit hook covers every way of writing a file. Install it once and it applies to every repository on the machine, including ones created later:

```bash
~/.vibeguard/bin/vibeguard-runtime install git-size --dry-run
~/.vibeguard/bin/vibeguard-runtime install git-size
~/.vibeguard/bin/vibeguard-runtime status git-size
~/.vibeguard/bin/vibeguard-runtime uninstall git-size
```

Nothing is added to your repositories. To turn it off in one, such as someone else's project with large files:

```bash
git -C /absolute/path/to/repository config vibeguard.sizeLimit false
```

It compares staged content with `HEAD`, so no list of known large files is needed. It is separate from `install git`, so it brings no push rules. How it installs depends on the global `core.hooksPath`:

- **Not set:** Git is pointed at `~/.vibeguard/git-hooks`, whose hooks also run each repository's own hooks, so those keep working. Uninstall unsets it again.
- **Set by another tool:** a marked block goes at the top of that tool's pre-commit script, and uninstall restores its exact text. If that tool rewrites the script, `status git-size` shows the block is gone; run install again. A hook that isn't a shell script is left alone and install fails with a message.

If the binary is missing, or the check itself fails, the commit goes through with a warning at most: a problem here must not stop every commit on the machine.

Known gaps:

- `git commit --no-verify` skips the commit hook. Rebases and fast-forward merges don't run it.
- A repository that sets its own `core.hooksPath`, as Husky does, doesn't run it.
- The Bash notice reads the whole repository, so it can also report another session's uncommitted growth. It misses a directory held in a shell variable.
- Grok and DSH receive no notice, and Codex `apply_patch` is seen only at commit.

Upgrading from 2.1: run `install claude` again to add the edit check. Files that are already over the limit stay as they are until someone splits them.

## What is enforced

| Surface | Behavior |
|---|---|
| Bash PreToolUse | Recognizes bulk `git checkout/restore .`, forced `git clean` without specific paths (dry runs excepted), and selected recursive forced deletion of root, home, or system paths. |
| Bash results | Records only the latest reported outcome, optional exit code, timestamp, cwd, and tool-use ID. No raw command or output. |
| Git pre-push | Rejects remote ref deletion and existing tag replacement. Branches require direct commit targets and fast-forward updates; other existing refs require commit ancestry after peeling tags. Missing required objects are an explicit error. See the [runtime contract](docs/runtime-contract.md). |
| Write/Edit/MultiEdit PreToolUse (Claude Code) | Refuses an edit that would leave a source file above 800 lines and longer than before. Edits whose result cannot be predicted (missing file, unmatched text) are left to the host tool. |
| Bash PostToolUse (Claude Code, Codex) and PostToolUseFailure (Claude Code) | Tells the Agent which source files grew past 800 lines, once per file and line count. It never changes a decision. |
| Git pre-commit (`install git-size`) | Refuses a commit that leaves a source file above 800 lines and longer than before. See [the 800-line limit](#the-800-line-limit). |

The Bash classifier is not a complete shell parser or a sandbox. Alternate commands, scripts, substitutions, other tools, and disabled or untrusted hooks can bypass it. Git hooks are also bypassable. Use host permissions and repository protection for access control.

`status` reports registration, required executable mode bits, local host hook settings, and the last observation. Prompt text is not an installation-health requirement. It cannot prove host trust, ACL access, mount execution policy, or complete coverage. A reported zero exit code does not certify that tests ran or that the current tree is verified.

For incomplete host status, and version-specific command
questions, see the [website task guide and FAQ](https://majiayu000.github.io/vibeguard/#faq).

## Breaking v2 changes

Removed the app-server proxy, package-manager rewriting, semantic grep scanners, Stop/test-keyword gates, profiles, learning/scoring systems, workflow routing, and duplicate scripts; 2.2.0 also removed the rule library and `rules` command. The Rust runtime remains: each hook invocation starts, processes one event, and exits.

There are no old command aliases, rule-ID aliases, data migration, or general automatic v1 cleanup. For an existing v1 installation, follow that version's uninstall instructions first. V2 normally owns only its exact hook command and existing `vibeguard-core` Markdown block. Install and uninstall remove that block without adding replacement guidance. Status no longer reports `core_present`. Uninstall removes the selected integration and observation, but leaves the shared binary for other integrations and direct use.

Claude install/reinstall specifically removes retired `skills-loader.sh` command handlers, including manually added duplicates. It recognizes simple calls through known VibeGuard installed/release paths (optionally through `bash` or `sh`) and the old `.vibeguard/run-hook.sh skills-loader.sh` wrapper. Same-name scripts in arbitrary paths are preserved. Other handlers and group fields are preserved; only groups emptied by removal are dropped. `--dry-run` reports the removal count without writing. This does not scan skills or delete legacy files; `status` remains read-only. See the [installation contract](docs/runtime-contract.md#installation) for the matching boundary.

`status`, `install`, and `uninstall` include a read-only `legacy` inventory. It lists known v1 hook commands, `<!-- vibeguard-start -->` regions, v1 files under `~/.vibeguard`, launchd and systemd unit files, and the account crontab when the selected home is this account's home. `--repo` adds that repository's root instruction files and its `pre-commit` and `pre-push` hooks. A different `--home` leaves the account crontab unread. `owned` and `suspected` record presence; they do not show that those commands ran. The inventory leaves every reported file in place.

Back up the reported files, then uninstall v1 with its own command: `bash setup.sh --clean` in the v1 source checkout, or `bash ~/.vibeguard/dist/current/setup.sh --clean` for a release snapshot. Deleting the checkout leaves hooks and scheduler entries behind. Install v2 from source with `bash setup.sh install codex`, or from an extracted release archive with `./vibeguard-runtime install codex`. Restart the host and read `status`.

The optional [Codex plugin](plugins/vibeguard/README.md) provides one explicit help skill. It does not install the runtime or hooks.

## Evidence and development

Run `bash scripts/local-contract-check.sh` for the local gate. Tests use temporary homes and repositories, including execution of generated hook commands. See the [evaluation protocol](eval/README.md): code tests do not establish an Astra/Fable productivity improvement.

The [reconstruction design](plan/2026-09-17-frontier-model-reconstruction.md) and [125-rule audit](plan/2026-09-17-rule-by-rule-audit.md) explain decisions and official sources. See [directory ownership](docs/directory-map.md) and [tagged releases](https://github.com/majiayu000/vibeguard/releases).
