# VibeGuard Codex App Plugin

This plugin makes VibeGuard discoverable from Codex App through a local Codex
marketplace. It intentionally does not auto-install hooks when the plugin is
loaded. Hook installation changes high-context user files such as
`~/.codex/AGENTS.md`, `~/.codex/hooks.json`, and `~/.codex/config.toml`, so the
plugin exposes explicit setup and status skills instead.

## Local Test Flow

From the VibeGuard repository root:

```bash
codex plugin marketplace add .
codex plugin add vibeguard@vibeguard-local
```

After installing the plugin, start a new Codex thread so the plugin skills are
loaded. Use the setup skill to run one of:

```bash
bash plugins/vibeguard/scripts/vibeguard-plugin.sh check --strict
bash plugins/vibeguard/scripts/vibeguard-plugin.sh codex-status
bash plugins/vibeguard/scripts/vibeguard-plugin.sh install --yes
```

If the plugin is loaded from a cache that is not inside a VibeGuard checkout,
set `VIBEGUARD_REPO_DIR=/path/to/vibeguard` before running the script.
