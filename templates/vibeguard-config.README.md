# VibeGuard user config (`~/.vibeguard/config.json`)

User-level runtime tuning for hook thresholds. A repository policy file
`.vibeguard.json` can override the same runtime paths for that project alongside
project policy keys such as `profile`, `enforcement`, `disabled_hooks`,
`disabled_rules`, `disabled_guards`, `scoped_suppressions`, and `gc`.

Hooks resolve each runtime value in priority order:

1. **Environment variable** (highest) — e.g. `VG_U16_LIMIT=1500 cargo build`
2. **Project config** — the same JSON path in `.vibeguard.json`
3. **User config** — `~/.vibeguard/config.json` (this file)
4. **Built-in default** (lowest)

Malformed JSON and invalid explicit values fail visibly. Missing values fall
through to the next layer.

To inspect the effective value and its source:

```sh
vibeguard-runtime config explain u16.limit --cwd /path/to/project
```

## Keys

| JSON path | Env var | Default | Effect |
|-----------|---------|---------|--------|
| `u16.warn_limit` | `VG_U16_WARN_LIMIT` | `400` | Source-file typical-size advisory threshold. Files over this and below `u16.limit` warn without blocking. |
| `u16.limit` | `VG_U16_LIMIT` | `800` | Source-file line limit. Files over this trigger block on `Write`/`Edit` and warn after `PostToolUse`. Per-file `CLAUDE.md` exemptions (`U-16 exempt: \`pattern\` → N`) can raise it further per repo. |
| `circuit_breaker.threshold` | `VG_CB_THRESHOLD` | `3` | Consecutive blocks before the hook circuit trips OPEN (silences batch advisories). |
| `circuit_breaker.cooldown_seconds` | `VG_CB_COOLDOWN` | `300` | Seconds an OPEN circuit waits before HALF-OPEN. |
| `circuit_breaker.lock_timeout_seconds` | `VG_CB_LOCK_TIMEOUT_SECONDS` | `5` | Seconds to wait for the circuit-breaker state lock. |
| `w14.cooldown_seconds` | `VIBEGUARD_W14_COOLDOWN_SECONDS` | `3600` | Suppresses repeated W-14 reports for the same directed session pair and file; `0` disables suppression. |
| _(env only)_ | `VIBEGUARD_W14_SKIP_TEMP` | unset | Set to exactly `0` to keep W-14 **and** churn active on system temp roots (`/tmp`, `/private/tmp`, `/var/folders`). By default those paths are exempt because a session-scoped scratchpad cannot have cross-session write conflicts. Repository paths are never exempt, including a repo-local `scratchpad/` directory. |
| `paralysis.threshold` | `VG_PARALYSIS_THRESHOLD` | `7` | W-13 read-only-action streak before paralysis warning. |
| `write_mode` | `VIBEGUARD_WRITE_MODE` | `warn` | `warn` = advisory; `block` = hard reject new source files without prior search. |
| `write_escalate_threshold` | `VIBEGUARD_PRE_WRITE_ESCALATE_THRESHOLD` | `5` | Search-first reminders in one session before write mode escalates to block; `0` disables escalation. |
| `learn.metrics_tail_bytes` | `VIBEGUARD_LEARN_METRICS_TAIL_BYTES` | `5242880` | Maximum recent metrics bytes read by the learn evaluator. |
## Example: raise U-16 for a Rust-heavy machine

```json
{
  "version": 1,
  "u16": { "warn_limit": 600, "limit": 1200 }
}
```

## Example: per-shell one-off override

```sh
VG_U16_LIMIT=2000 git commit -m "checkpoint"
```

## How to edit

```sh
$EDITOR ~/.vibeguard/config.json
```

`setup.sh` seeds this file from `templates/vibeguard-config.json.example` on first install and never overwrites your edits afterward. Re-running `setup.sh` is safe.
