---
name: vibeguard-setup
description: Use when the user asks to install, verify, inspect, or remove VibeGuard Codex hooks through the Codex App plugin.
---

# VibeGuard Setup

This skill operates the explicit setup bridge for the VibeGuard Codex App
plugin. Installing VibeGuard changes high-context user configuration, so always
show the intended command before running it.

## When to Activate

- User asks to install VibeGuard hooks, rules, or skills for Codex.
- User asks to check VibeGuard health, hook status, or Codex status.
- User asks to uninstall or clean VibeGuard-managed assets.

## Red Flags

- **Missing checkout** - the plugin cache alone is not enough to install VibeGuard source assets.
- **Implicit install** - do not run `install --yes` unless the user asked to install.
- **Stale status** - do not report VibeGuard as healthy without a fresh setup check.

## Checklist

- [ ] Resolve the source checkout with `plugins/vibeguard/scripts/vibeguard-plugin.sh repo-dir`.
- [ ] Run `plugins/vibeguard/scripts/vibeguard-plugin.sh check --strict` before claiming health.
- [ ] Use `plugins/vibeguard/scripts/vibeguard-plugin.sh codex-status` for Codex-specific setup state.
- [ ] Use `VIBEGUARD_REPO_DIR=/path/to/vibeguard` if the plugin is loaded outside the checkout.

## Commands

From a VibeGuard checkout:

```bash
bash plugins/vibeguard/scripts/vibeguard-plugin.sh repo-dir
bash plugins/vibeguard/scripts/vibeguard-plugin.sh check --strict
bash plugins/vibeguard/scripts/vibeguard-plugin.sh codex-status
bash plugins/vibeguard/scripts/vibeguard-plugin.sh doctor
bash plugins/vibeguard/scripts/vibeguard-plugin.sh install --yes
bash plugins/vibeguard/scripts/vibeguard-plugin.sh clean
```

When running from a plugin cache:

```bash
VIBEGUARD_REPO_DIR=/path/to/vibeguard \
  bash scripts/vibeguard-plugin.sh check --strict
```
