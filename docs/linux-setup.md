# Linux Setup Guide

VibeGuard supports Linux via **systemd user units** as the scheduled task mechanism (equivalent to macOS launchd).

## Requirements

- `gh` or `curl` for the default prebuilt `vibeguard-runtime` download.
  Authenticated `gh` also enables artifact attestation verification; without it,
  setup reports `checksum-only` after SHA-256 verification. Use
  `--require-provenance` when checksum-only installs should fail closed.
- Python 3 is not required for default production install/check/clean on
  supported release targets. It remains used by evals, docs generation,
  developer tools, and optional Python-backed guard tools.
- Rust/Cargo only for unsupported targets, offline installs, or `--build-from-source`.
- Linux with systemd, `systemctl` in `$PATH`, and a `systemd --user` session only if
  you opt in to the scheduled GC timer.

## Installation

Run the standard setup script to install VibeGuard without a background scheduler:

```bash
bash setup.sh --yes
```

On `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl`, release
checkouts whose pinned runtime version has published assets download a release
binary, verify it against `SHA256SUMS`, and print either `verified-provenance`
or `checksum-only` for release provenance. Rust/Cargo is not required for that
released-assets path. Unreleased `main` checkouts can pin a runtime version
before assets exist; those installs fall back to a local Cargo build unless
`--require-provenance` is set. To force a local build:

```bash
bash setup.sh --yes --build-from-source
```

For stricter supply-chain environments, require GitHub artifact attestation
verification in addition to the checksum:

```bash
bash setup.sh --yes --require-provenance
```

This mode fails instead of falling back to `checksum-only` when `gh`,
`gh attestation verify`, or GitHub authentication is unavailable. It also rejects
`--build-from-source`, because release provenance only exists for published
release assets.

Scheduled GC is opt-in. To install and enable the systemd timer:

```bash
bash setup.sh --yes --with-scheduler
```

The opt-in scheduler path will:
1. Copy `scripts/systemd/vibeguard-gc.{service,timer}` to `~/.config/systemd/user/`
2. Substitute `__VIBEGUARD_DIR__` and `__HOME__` with the actual paths
3. Enable and start `vibeguard-gc.timer` via `systemctl --user enable --now`

You can also run GC on demand:

```bash
/vibeguard:gc
bash scripts/gc/gc-scheduled.sh
```

### Manual installation

If you prefer to install only the systemd units:

```bash
bash scripts/install-systemd.sh
```

### Removal

```bash
bash scripts/install-systemd.sh --remove
```

## Schedule

The timer fires every **Sunday at 3:00 AM** (same schedule as the macOS launchd plist).

The `Persistent=true` directive ensures the GC runs at the next opportunity if the machine was off at the scheduled time.

## Logs

| File | Contents |
|------|----------|
| `~/.vibeguard/gc-systemd.log` | stdout + stderr from `gc-scheduled.sh` |
| `~/.vibeguard/gc-cron.log` | GC run log written by `gc-scheduled.sh` itself |

To tail the log:

```bash
tail -f ~/.vibeguard/gc-systemd.log
```

To view systemd journal output:

```bash
journalctl --user -u vibeguard-gc.service
```

## Status check

```bash
# Human-friendly VibeGuard doctor report
bash setup.sh doctor

# CI/post-install verification; exits non-zero on broken required state
bash setup.sh verify-install

# Via systemctl directly
systemctl --user status vibeguard-gc.timer
systemctl --user list-timers vibeguard-gc.timer
```

`bash setup.sh --check` remains a compatibility alias for `doctor`. Existing
machine callers can migrate from `--check --strict` to `verify-project`, from
`--check --json` to `verify-project --json`, and from `--check --install` to
`verify-install`.

## Troubleshooting

**Timer not starting after install:**

```bash
# Reload unit files and retry
systemctl --user daemon-reload
systemctl --user enable --now vibeguard-gc.timer
```

**`systemctl --user` commands fail with "Failed to connect to bus":**

Your user session may not have a D-Bus socket. This can happen in minimal containers.
Run `loginctl enable-linger $USER` to enable persistent user services, or start a user session with `systemd-run --user`.

**Verify the next scheduled run:**

```bash
systemctl --user list-timers --all | grep vibeguard
```

## Unit file locations

| File | Destination |
|------|-------------|
| `scripts/systemd/vibeguard-gc.service` | Template (source) |
| `scripts/systemd/vibeguard-gc.timer` | Template (source) |
| `~/.config/systemd/user/vibeguard-gc.service` | Installed unit |
| `~/.config/systemd/user/vibeguard-gc.timer` | Installed unit |
