---
name: vibeguard-observe
description: Use when the user asks for a VibeGuard dashboard, hook health, stats, doctor output, metrics export, or local observability status from the Codex App plugin.
---

# VibeGuard Observe

This skill uses VibeGuard's local observability commands through the Codex App
plugin bridge. Observability is local-first: use repository scripts and local
JSONL logs before discussing external telemetry.

## When to Activate

- User asks to show a VibeGuard dashboard or GUI.
- User asks whether hooks are installed, noisy, slow, warning, blocking, or stale.
- User asks for project/global hook stats, health, doctor output, or metrics.
- User asks to inspect the VibeGuard website/product page from the plugin.

## Red Flags

- **No custom Codex panel** - the documented plugin manifest does not expose a local HTML panel field. Use the generated local dashboard instead.
- **Runtime/eval collapse** - hook health and eval quality are separate surfaces.
- **Remote telemetry drift** - do not enable Prometheus, Victoria, OpenTelemetry, or hosted Sites by default.
- **Raw data leak** - do not paste local logs, prompts, secrets, or full command payloads unless the user explicitly asks and it is safe.

## Checklist

- [ ] Resolve the source checkout with `plugins/vibeguard/scripts/vibeguard-plugin.sh repo-dir`.
- [ ] Use `dashboard` for a local HTML overview.
- [ ] Use `health` for recent hook health.
- [ ] Use `stats` for project/global trigger summaries.
- [ ] Use `doctor` or `codex-status` for install/capability diagnosis.
- [ ] Keep setup changes explicit; do not install hooks while answering observe-only requests.

## Commands

From a VibeGuard checkout:

```bash
bash plugins/vibeguard/scripts/vibeguard-plugin.sh dashboard
bash plugins/vibeguard/scripts/vibeguard-plugin.sh dashboard --no-open --output /tmp/vibeguard-dashboard.html
bash plugins/vibeguard/scripts/vibeguard-plugin.sh health 24
bash plugins/vibeguard/scripts/vibeguard-plugin.sh stats all
bash plugins/vibeguard/scripts/vibeguard-plugin.sh stats --scope global all
bash plugins/vibeguard/scripts/vibeguard-plugin.sh doctor
bash plugins/vibeguard/scripts/vibeguard-plugin.sh metrics-export
bash plugins/vibeguard/scripts/vibeguard-plugin.sh open-site
```

When running from a plugin cache:

```bash
VIBEGUARD_REPO_DIR=/path/to/vibeguard \
  bash scripts/vibeguard-plugin.sh dashboard --no-open
```
