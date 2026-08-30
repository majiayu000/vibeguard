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
- [ ] Use `dashboard` for a local HTML first-win overview.
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

## Dashboard evidence boundary

The dashboard's headline cards come only from the selected runtime's
`observe value --json` output. They do not parse or infer evidence from human
`stats` or `health` output. The first screen separates:

- verified later `post-build-check` pass associations in the same session;
- observed ordinary follow-up, unresolved attention sessions, and hook
  overhead;
- observed friction such as repeated attention, suppressions, and
  uncorrelatable events.

The dashboard is a standalone local HTML file with no network assets,
telemetry, upload, account, or server. Installation state and raw diagnostics
are secondary and live in escaped collapsible details. Missing, empty,
partial/unresolved, malformed, failed, and unsupported evidence states remain
explicit. The dashboard does not claim causality, incidents prevented,
token/time/money savings, or compliance. The built-in 5-positive/5-negative
benchmark is a small reproducible corpus, not evidence of impact on the
user's project.

If the selected runtime lacks `observe value`, update or build the runtime and
regenerate the dashboard. The dashboard flags remain available, and
`--project` is still rejected together with `--scope global`.
