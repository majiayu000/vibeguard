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

The generated dashboard is local-only and standalone. Its headline evidence is
read from the selected runtime's `observe value --json` output, never inferred
from human stats or health text. The first screen keeps these tiers separate:

- **Verified association:** a strictly later `post-build-check` pass in the
  same session after attention. This is time-ordered local evidence, not proof
  that VibeGuard caused the pass.
- **Observed signals:** later ordinary follow-up passes, unresolved attention
  sessions, and observed hook duration.
- **Observed friction:** repeated-attention sessions, suppressions, and
  uncorrelatable attention events.

Installation state and human status/stats/health output remain secondary in
collapsible diagnostic details. Raw output is HTML-escaped. Missing, empty,
partial, malformed, failed, and unsupported evidence states are shown
explicitly; unavailable evidence is never replaced with zero. The page makes
no claims about incidents prevented, token/time/money savings, or compliance.

The built-in 5-positive/5-negative benchmark is a small reproducible corpus,
not evidence of impact on the user's project. If the selected runtime does not
support `observe value`, the dashboard shows an actionable update/build
message while preserving the existing dashboard flags, including the explicit
rejection of `--project` with `--scope global`.
