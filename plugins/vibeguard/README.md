# VibeGuard Codex App Plugin

This plugin makes VibeGuard observability discoverable from Codex App through a
local Codex marketplace. It exposes hook health, trigger stats, Codex setup
diagnosis, metric export, and a generated local dashboard.

It intentionally does not auto-install hooks when the plugin is loaded. Hook
installation changes high-context user files such as `~/.codex/AGENTS.md`,
`~/.codex/hooks.json`, and `~/.codex/config.toml`, so setup remains an explicit
user action.

## Local Test Flow

From the VibeGuard repository root:

```bash
codex plugin marketplace add .
codex plugin add vibeguard@vibeguard-local
```

After installing the plugin, start a new Codex thread so the plugin skills are
loaded. Use the observe/setup skills to run one of:

```bash
bash plugins/vibeguard/scripts/vibeguard-plugin.sh dashboard
bash plugins/vibeguard/scripts/vibeguard-plugin.sh health 24
bash plugins/vibeguard/scripts/vibeguard-plugin.sh stats all
bash plugins/vibeguard/scripts/vibeguard-plugin.sh doctor
bash plugins/vibeguard/scripts/vibeguard-plugin.sh check --strict
bash plugins/vibeguard/scripts/vibeguard-plugin.sh codex-status
bash plugins/vibeguard/scripts/vibeguard-plugin.sh install --yes
```

If the plugin is loaded from a cache that is not inside a VibeGuard checkout,
set `VIBEGUARD_REPO_DIR=/path/to/vibeguard` before running the script.

## Local Dashboard

The dashboard command writes a local HTML artifact from current VibeGuard
diagnostics and opens it on macOS:

```bash
bash plugins/vibeguard/scripts/vibeguard-plugin.sh dashboard
```

For headless validation:

```bash
bash plugins/vibeguard/scripts/vibeguard-plugin.sh dashboard --no-open --output /tmp/vibeguard-dashboard.html --log-file /dev/null
```

The generated dashboard is local-only. It renders the same human-facing status,
stats, and health outputs that VibeGuard already provides; it does not enable
remote telemetry or hosted deployment.
