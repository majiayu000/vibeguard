# Linux Setup Guide

VibeGuard supports Linux via **systemd user units** as the scheduled task mechanism (equivalent to macOS launchd).

## Requirements

- Linux with systemd (most modern distros: Ubuntu 16.04+, Debian 9+, Fedora, Arch, etc.)
- `systemctl` available in `$PATH`
- A user session with `systemd --user` support (most desktop/server setups)

## Installation

Run the standard setup script — it automatically detects Linux and installs the systemd timer:

```bash
bash setup.sh
```

The installer will:
1. Copy `scripts/systemd/vibeguard-gc.{service,timer}` to `~/.config/systemd/user/`
2. Substitute `__VIBEGUARD_DIR__` and `__HOME__` with the actual paths
3. Enable and start `vibeguard-gc.timer` via `systemctl --user enable --now`

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
# Via VibeGuard check script
bash setup.sh --check

# Via systemctl directly
systemctl --user status vibeguard-gc.timer
systemctl --user list-timers vibeguard-gc.timer
```

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
