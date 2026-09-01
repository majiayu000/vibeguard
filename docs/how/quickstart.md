# Quickstart

Use this path to prove VibeGuard is installed, healthy, and intercepting a real
agent action before you rely on it in another repository.

## 1. Install

```bash
git clone https://github.com/majiayu000/vibeguard.git ~/vibeguard
bash ~/vibeguard/setup.sh --yes
```

On supported macOS/Linux release targets, setup downloads a prebuilt
`vibeguard-runtime` release binary and verifies its checksum when the pinned
runtime version has published assets. Source builds are needed for unsupported
targets, offline installs, explicit `--build-from-source` runs, or unreleased
`main` checkouts whose `vibeguard-runtime/VERSION` is ahead of the latest tag.

## 2. Verify

```bash
export PATH="$HOME/.vibeguard/installed/bin:$PATH"
bash ~/vibeguard/setup.sh doctor
bash ~/vibeguard/setup.sh verify-install
```

Expected result on a healthy machine:

- `doctor` prints a human-readable `HEALTHY` report.
- `verify-install` exits 0 and is suitable for CI or post-install checks.
- Broken required install state is reported as non-zero instead of silently
  passing.

For Codex-specific hook state, run:

```bash
bash ~/vibeguard/scripts/doctors/codex-doctor.sh
```

## 3. Bootstrap a Project

```bash
cd /path/to/project
bash ~/vibeguard/scripts/project-init.sh --no-hooks "$PWD"  # inspect only
bash ~/vibeguard/scripts/project-init.sh "$PWD"
```

The first command detects the project and prints a `Suggested agent guidance
snippet` without writing Git hooks. The second repeats the report and installs
the shared pre-commit/pre-push wrappers when they are available. Neither command
modifies `AGENTS.md` or `CLAUDE.md`; review and save the snippet in the guidance
file for the agent host you use. Open a new Claude Code or Codex session after
saving that guidance so the agent loads the updated instructions and hooks.

Run `bash ~/vibeguard/scripts/project-init.sh --help` for the complete command
contract.

`project-init.sh` only bootstraps repositories where it detects a known
language marker such as `Cargo.toml`, `tsconfig.json`, `package.json`,
`go.mod`, `pyproject.toml`, or `requirements.txt`. Shell-only, docs-only, and
other unrecognized repositories print `No known language detected, skipping.`
and do not get git hooks from this command.

## 4. Configure Runtime Thresholds

Initialize a persistent override only when needed, then inspect the effective
values and source layers:

```bash
vibeguard-runtime config init --scope user
vibeguard-runtime config show --cwd "$PWD"
vibeguard-runtime config set churn.warning_edit_count 12 --scope project --cwd "$PWD"
vibeguard-runtime config reset churn.warning_edit_count --scope project --cwd "$PWD"
```

Churn guidance defaults to 5 informational edits, 10 warning edits, 20
review-level edits, and 5 build failures for critical escalation. W-15 defaults
to a three-edit trail and a latest-delta ceiling of 300 characters. Raising the
W-15 trail minimum waits for more consecutive edits but still evaluates only
the latest three deltas. See
[`vibeguard-config.README.md`](../../templates/vibeguard-config.README.md) for
all supported fields, environment overrides, and scope rules.

## 5. Run One Intercepted Demo

Start with the live, fail-closed interception demo:

```bash
bash ~/vibeguard/setup.sh demo safe-bash
```

This protects the demo's temporary `HOME` directory from the destructive
`rm -rf $HOME` request. That matters because the same command could erase a
user's local state. The sandbox marker verifies that the protected temporary
directory remains intact after the real `PreToolUse(Bash)` hook returns
`block`; the dangerous command is never handed to a shell executor. A
malformed, failed, or non-block hook result stops the demo. This is isolated
demo evidence, not evidence from your real project.

Then try one live agent action in a disposable branch or scratch project:

```text
Ask the agent to create a new source file that duplicates an existing module name without searching first.
```

Expected behavior: VibeGuard emits a search-first warning or block with a fix
instruction. If no hook output appears, use [Troubleshooting](troubleshooting.md)
before assuming protection is active.

## 6. Inspect Recent Hook Status

```bash
vibeguard observe health --limit all
```

This summarizes recent local hook events for the current project. See
[Codex Hook Status](../reference/codex-hook-status.md) for JSON and global-scope
diagnostics.

## 6. Find the First Win in Your Project

After a protected action has run in the project, inspect the bounded local
event evidence:

```bash
vibeguard observe value --json
bash ~/vibeguard/plugins/vibeguard/scripts/vibeguard-plugin.sh dashboard
```

The dashboard reads its headline cards from `observe value --json`. It keeps
verified later build-pass associations separate from observed follow-up,
unresolved attention sessions, and hook overhead. Missing, empty, partial, or
unavailable evidence stays visible; the dashboard does not claim causality,
incidents prevented, savings, or compliance.
