# Quickstart

Use this path to prove VibeGuard is installed, healthy, and intercepting a real
agent action before you rely on it in another repository.

## 1. Install

```bash
git clone https://github.com/majiayu000/vibeguard.git ~/vibeguard
bash ~/vibeguard/setup.sh --yes
```

On supported macOS/Linux targets, setup downloads a prebuilt
`vibeguard-runtime` release binary and verifies its checksum. Source builds are
only needed for unsupported targets, offline installs, or explicit
`--build-from-source` runs.

## 2. Verify

```bash
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

This installs project guidance and the shared pre-commit wrapper for that
repository. Open a new Claude Code or Codex session after bootstrapping so the
agent loads the updated instructions and hooks.

## 4. Run One Intercepted Demo

Start with the side-effect-free demo:

```bash
bash ~/vibeguard/setup.sh demo safe-bash
```

Then try one live agent action in a disposable branch or scratch project:

```text
Ask the agent to create a new source file that duplicates an existing module name without searching first.
```

Expected behavior: VibeGuard emits a search-first warning or block with a fix
instruction. If no hook output appears, use [Troubleshooting](troubleshooting.md)
before assuming protection is active.

## 5. Inspect Recent Hook Status

```bash
bash ~/vibeguard/scripts/hook-health.sh 24
~/.vibeguard/installed/bin/vibeguard-runtime hook-status --mode focused
```

`hook-health.sh` summarizes recent local hook events. `hook-status` shows the
project-scoped hook log for the current git repository; see
[Codex Hook Status](../reference/codex-hook-status.md) for JSON and global-scope
diagnostics.
