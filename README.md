# VibeGuard

A Rust CLI for coding-agent rules, native hooks, and installation diagnostics.

[中文](docs/README_CN.md) · [Runtime contract](docs/runtime-contract.md) · [Rule reference](docs/rule-reference.md) · [Contributing](CONTRIBUTING.md)

V2 keeps six short principles in host instructions and embeds 75 scoped review topics in one binary. Look up a relevant topic when needed. The library covers scope, facts, errors, security, workflow, Rust, Python, Go, and TypeScript.

Native Bash hooks reject a small set of destructive command spellings and record the latest observed outcome. An optional Git pre-push hook checks actual commit ancestry. The host owns permissions, sandboxing, tool execution, and the agent loop.

## Install from a release archive

Download the archive for your OS and CPU from [Releases](https://github.com/majiayu000/vibeguard/releases), extract it, and open a terminal in the extracted directory. macOS, Linux and WSL are supported; choose a Linux archive for WSL. No Rust toolchain or source checkout is required for this path. Run:

```bash
./vibeguard-runtime install codex
# Or select Claude Code:
./vibeguard-runtime install claude
```

The archive contains the executable, this README and LICENSE. Installation copies the executable to `~/.vibeguard/bin/vibeguard-runtime`. Restart the selected host and review its native hook trust settings. Check or remove that integration with:

```bash
~/.vibeguard/bin/vibeguard-runtime status codex
~/.vibeguard/bin/vibeguard-runtime uninstall codex
```

Use `claude` instead of `codex` for Claude Code. Uninstall retains the shared executable. V2 archives become available when a maintainer publishes v2; earlier release assets follow their own version's instructions.

## Build and install from source

Source builds require Git and the Rust toolchain pinned in `rust-toolchain.toml`. Native installation supports macOS, Linux, and WSL. Native Windows installation is not implemented; the portable CLI and JSON protocol are tested in Windows CI.

```bash
git clone https://github.com/majiayu000/vibeguard.git
cd vibeguard
bash setup.sh --help
bash setup.sh install codex
# Or select Claude Code:
bash setup.sh install claude
```

`setup.sh` builds the checked-out source and forwards arguments. Without arguments it prints help; it does not install automatically. Install copies the binary to `~/.vibeguard/bin/vibeguard-runtime` and registers the selected integration. Restart the host and review its native hook trust settings.

```bash
~/.vibeguard/bin/vibeguard-runtime rules
~/.vibeguard/bin/vibeguard-runtime rules RS-01
~/.vibeguard/bin/vibeguard-runtime rules typescript
~/.vibeguard/bin/vibeguard-runtime status codex
~/.vibeguard/bin/vibeguard-runtime uninstall codex
```

Categories: `common`, `rust`, `python`, `golang`, `typescript`. `rules --json` exports the catalog; `rules --core` prints the compact instructions.

Git protection is explicit: `~/.vibeguard/bin/vibeguard-runtime install git --repo /absolute/path/to/repository`. It refuses to replace a user-managed pre-push hook. Use `status git` or `uninstall git` with the same `--repo`.

## What is enforced

| Surface | Behavior |
|---|---|
| Bash PreToolUse | Recognizes bulk `git checkout/restore .`, forced `git clean` except dry runs, and selected recursive forced deletion of root, home, or system paths. |
| Bash results | Records only the latest reported outcome, optional exit code, timestamp, cwd, and tool-use ID. No raw command or output. |
| Git pre-push | Rejects remote ref deletion and existing tag replacement. Branches require direct commit targets and fast-forward updates; other existing refs require commit ancestry after peeling tags. Missing required objects are an explicit error. See the [runtime contract](docs/runtime-contract.md). |
| Rule library | Advice with scope and exceptions. Severity is not an automatic blocking level. |

The Bash classifier is not a complete shell parser or a sandbox. Alternate commands, scripts, substitutions, other tools, and disabled or untrusted hooks can bypass it. Git hooks are also bypassable. Use host permissions and repository protection for access control.

`status` reports registration, managed instructions, required executable mode bits, the local disable flag, and the last observation. It cannot prove host trust, ACL access, mount execution policy, or complete coverage. A reported zero exit code does not certify that tests ran or that the current tree is verified.

## Breaking v2 changes

Removed the app-server proxy, package-manager rewriting, semantic grep scanners, Stop/test-keyword gates, profiles, learning/scoring systems, workflow routing, and duplicate scripts. The Rust runtime remains: each hook invocation starts, processes one event, and exits.

There are no old command aliases, rule-ID aliases, data migration, or automatic v1 cleanup. For an existing v1 installation, follow that version's uninstall instructions first. V2 owns only its exact hook command and `vibeguard-core` Markdown block. Uninstall removes the selected integration and observation, but leaves the shared binary for other integrations and direct use.

`status`, `install`, and `uninstall` include a read-only `legacy` inventory. It lists known v1 hook commands, `<!-- vibeguard-start -->` regions, v1 files under `~/.vibeguard`, launchd and systemd unit files, and the account crontab when the selected home is this account's home. `--repo` adds that repository's root instruction files and its `pre-commit` and `pre-push` hooks. A different `--home` leaves the account crontab unread. `owned` and `suspected` record presence; they do not show that those commands ran. The inventory leaves every reported file in place.

Back up the reported files, then uninstall v1 with its own command: `bash setup.sh --clean` in the v1 source checkout, or `bash ~/.vibeguard/dist/current/setup.sh --clean` for a release snapshot. Deleting the checkout leaves hooks and scheduler entries behind. Install v2 from source with `bash setup.sh install codex`, or from an extracted release archive with `./vibeguard-runtime install codex`. Restart the host and read `status`.

The optional [Codex plugin](plugins/vibeguard/README.md) provides one explicit help skill. It does not install the runtime or hooks.

## Evidence and development

Run `bash scripts/local-contract-check.sh` for the local gate. Tests use temporary homes and repositories, including execution of generated hook commands. See the [evaluation protocol](eval/README.md): code tests do not establish an Astra/Fable productivity improvement.

The [reconstruction design](plan/2026-09-17-frontier-model-reconstruction.md) and [125-rule audit](plan/2026-09-17-rule-by-rule-audit.md) explain decisions and official sources. See [directory ownership](docs/directory-map.md). V2 is unreleased until a maintainer publishes a tagged release.
