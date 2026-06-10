# Codex App Observability Plugin Spec

## Status

Draft implementation for the repo-local VibeGuard Codex plugin.

## Problem

VibeGuard already has local observability surfaces for hook events, install
state, hook health, stats, doctor checks, and metric export. The Codex plugin
should make those surfaces discoverable from Codex App instead of presenting
VibeGuard as only an installer wrapper.

## Source Constraints

The Codex plugin contract supports:

- `.codex-plugin/plugin.json` for plugin metadata and install-surface copy.
- `skills/` for task workflows.
- optional app connector mappings through `.app.json`.
- optional MCP server config through `.mcp.json`.
- optional lifecycle hooks through plugin hook files, after user trust review.
- visual install-surface assets through `interface.composerIcon`, `logo`, and
  `screenshots`.

The currently documented plugin contract does not define a custom local HTML
panel field inside `plugin.json`. Codex Sites is a separate plugin for hosted
sites. Therefore this plugin must not invent a hidden GUI manifest field. The
supported design is:

- Codex App plugin card and default prompts point users toward observability.
- Bundled skills route observe/setup/doctor tasks.
- A bundled script generates a local HTML dashboard from VibeGuard's existing
  local evidence commands.
- Hook installation remains explicit and user-triggered.

## Goals

- Make VibeGuard's first Codex plugin impression observability-first.
- Expose project/global stats, hook health, Codex install status, doctor checks,
  metric export, and the existing product site from the plugin.
- Generate a local dashboard HTML file from current command output.
- Keep local logs as the source of truth; do not send observability data to a
  remote service by default.
- Keep setup and hook installation explicit.
- Preserve existing VibeGuard core architecture: rules, hooks, runtime, setup
  scripts, and observability commands remain the source implementation.

## Non-goals

- Do not add a custom unsupported `plugin.json` field for a GUI panel.
- Do not enable remote telemetry, Sites deployment, or hosted dashboards by
  default.
- Do not auto-install hooks during plugin discovery or install.
- Do not replace existing `site/` marketing/product pages.

## User Experience

After installing the repo-local marketplace plugin, a user should see VibeGuard
in the Codex plugin directory with observability-focused copy and starter
prompts such as:

- "Show my VibeGuard dashboard"
- "Check VibeGuard hook health"
- "Diagnose my Codex hook setup"

In a Codex thread, the plugin routes:

- "show my VibeGuard dashboard" to the dashboard generator.
- "check hook health" to the health command.
- "show stats" to the stats command.
- "diagnose setup" to the Codex doctor or status command.
- "install VibeGuard" to explicit setup, with the command shown first.

The local dashboard command writes an HTML artifact and opens it on macOS:

```bash
bash plugins/vibeguard/scripts/vibeguard-plugin.sh dashboard
```

For CI or headless validation:

```bash
bash plugins/vibeguard/scripts/vibeguard-plugin.sh dashboard --no-open --output /tmp/vibeguard-dashboard.html --log-file /dev/null
```

## Plugin Structure

```text
plugins/vibeguard/
  .codex-plugin/plugin.json
  README.md
  assets/
    logo-mark.svg
    logo-vibeguard.svg
  scripts/
    vibeguard-plugin.sh
  skills/
    vibeguard/
      SKILL.md
    vibeguard-observe/
      SKILL.md
    vibeguard-setup/
      SKILL.md
```

## Command Contract

`plugins/vibeguard/scripts/vibeguard-plugin.sh` supports:

| Command | Behavior |
|---|---|
| `repo-dir` | Print the resolved source checkout. |
| `codex-status` | Run `setup.sh --codex-status`. |
| `check` | Run `setup.sh --check`. |
| `install` | Run `setup.sh` with explicit user options. |
| `clean` | Run `setup.sh --clean`. |
| `stats` | Run `scripts/stats.sh`. |
| `health` | Run `scripts/hook-health.sh`. |
| `doctor` | Run `scripts/doctors/codex-doctor.sh`. |
| `metrics-export` | Run `scripts/metrics/metrics-exporter.sh`. |
| `open-site` | Open or print the existing product site path. |
| `dashboard` | Generate a local HTML dashboard from status, stats, and health outputs. |

The source checkout resolver keeps using:

1. `VIBEGUARD_REPO_DIR`.
2. plugin-relative checkout path.
3. current git root.
4. `$HOME/vibeguard`.

If no checkout is found, commands fail loudly and ask for `VIBEGUARD_REPO_DIR`.

## Dashboard Contract

The dashboard is a generated local HTML artifact. It includes:

- generation timestamp
- resolved checkout path
- Codex install status
- hook health snapshot
- trigger stats snapshot
- exact source commands for reproducibility
- next action hints

The dashboard does not read raw prompts, command payloads, secrets, or remote
telemetry. It renders command outputs that already exist as human-facing
VibeGuard diagnostics.

## Security and Privacy

- No auto-install: plugin install must not rewrite `~/.codex`, `~/.claude`, or
  hook config.
- No remote egress: dashboard generation stays local.
- No secrets in labels or dashboard metadata.
- Plugin docs must distinguish runtime health from eval quality.
- Any future plugin hook must go through Codex hook trust review and a separate
  security review.

## Validation

Focused plugin validation:

```bash
bash tests/test_codex_plugin_manifest.sh
```

Before submission:

```bash
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
bash scripts/ci/validate-skill-format.sh
bash tests/test_manifest_contract.sh
bash tests/test_setup.sh
cd vibeguard-runtime && cargo check
cd vibeguard-runtime && cargo test
```

## Future Work

- Add a hosted Sites project only after the local dashboard format is stable and
  reviewed.
- Add screenshots to the plugin install surface after the dashboard design is
  stable enough to render deterministic PNG fixtures.
- Add a sanitized Prometheus/Victoria adapter only after label allowlisting is
  test-backed.
