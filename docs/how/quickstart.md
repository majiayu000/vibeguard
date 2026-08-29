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
bash ~/vibeguard/scripts/project-init.sh "$PWD"
```

This prints a `Suggested project CLAUDE.md snippet` and installs the shared
pre-commit/pre-push wrappers when they are available. Save the suggested
snippet into the repository's `CLAUDE.md`, `AGENTS.md`, or equivalent project
guidance file before relying on agent-visible instructions. Open a new Claude
Code or Codex session after saving that guidance so the agent loads the updated
instructions and hooks.

`project-init.sh` only bootstraps repositories where it detects a known
language marker such as `Cargo.toml`, `tsconfig.json`, `package.json`,
`go.mod`, `pyproject.toml`, or `requirements.txt`. Shell-only, docs-only, and
other unrecognized repositories print `No known language detected, skipping.`
and do not get git hooks from this command.

## 4. Run One Intercepted Demo

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

## 5. Inspect Recent Hook Status

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
