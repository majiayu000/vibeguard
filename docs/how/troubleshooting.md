# Troubleshooting

Use this path when VibeGuard is installed but the visible behavior does not
match the expected hook, rule, or runtime state.

## Start with Install Health

```bash
bash ~/vibeguard/setup.sh doctor
bash ~/vibeguard/setup.sh verify-install
```

Read the final verdict first:

| Verdict | Meaning | Next Action |
|---------|---------|-------------|
| `HEALTHY` | Required install state is present | Inspect recent hook events if behavior still looks wrong |
| `DEGRADED` | Optional or recoverable state is missing | Read the warning row and rerun the suggested setup command |
| `BROKEN` | Required state is missing or inconsistent | Fix the broken row before relying on hooks |

`doctor` is meant for humans and stays friendly. `verify-install` is the
post-install/CI gate and returns non-zero for broken required state.

## Codex Hook State

```bash
bash ~/vibeguard/scripts/doctors/codex-doctor.sh
```

Check these fields separately:

- `~/.codex/AGENTS.md` contains the managed VibeGuard block.
- `~/.codex/hooks.json` has managed hooks with timeout fields.
- `~/.vibeguard/run-hook-codex.sh` exists and points at the installed runtime.
- Codex native hooks are limited to Bash/apply_patch/PermissionRequest/PostToolUse/Stop.

Read-only exploration hooks such as Read/Glob/Grep are not available on the
native Codex path. Use Claude Code or the optional app-server-wrapper when that
coverage is required.

## Runtime and Provenance

```bash
~/.vibeguard/installed/bin/vibeguard-runtime version
bash ~/vibeguard/setup.sh verify-install
```

Expected state:

- Supported macOS/Linux installs use a downloaded release binary by default.
- Setup verifies `SHA256SUMS`.
- Authenticated `gh` attestation verification reports `verified-provenance`.
- If attestation verification is unavailable, setup reports `checksum-only`
  rather than claiming provenance was verified.

Checksum mismatch or a missing checksum entry is fatal and should not be
treated as a source-build fallback.

## Recent Hook Events

Inside the repository where you expected a hook to run:

```bash
bash ~/vibeguard/scripts/hook-health.sh 24
~/.vibeguard/installed/bin/vibeguard-runtime hook-status --mode focused
```

For global logs:

```bash
~/.vibeguard/installed/bin/vibeguard-runtime hook-status --scope global --mode focused
```

If hook status reports no data, check whether the command is running inside the
intended git repository and whether the session was opened after setup.

## Common States

| Symptom | Likely Cause | Check |
|---------|--------------|-------|
| No hook output in a new session | Session was opened before setup or hooks are not enabled | Rerun `setup.sh doctor`, restart the agent session |
| Codex has rules but no hook events | `hooks.json` missing, hooks feature disabled, or no write/bash action occurred | Run `scripts/doctors/codex-doctor.sh` |
| `verify-install` fails but `doctor` looks readable | Human report is not the CI gate | Use the failing `verify-install` row as source of truth |
| Hook status shows only old events | Wrong project scope or stale session | Run `hook-status --scope global --mode focused`, then retry inside the target repo |
| Setup reports `checksum-only` | Attestation verification was unavailable | Install is checksum-verified, not provenance-verified |

## Linux Notes

Use [Linux Setup](../linux-setup.md) when shell, package manager, or service
manager differences are involved.

## Deeper References

- [Codex Hook Status](../reference/codex-hook-status.md)
- [Observability Harness Contract](../reference/observability-harness.md)
- [Claude Code Known Issues](../reference/claude-code-known-issues.md)
- [Known False Positives](../known-issues/false-positives.md)
