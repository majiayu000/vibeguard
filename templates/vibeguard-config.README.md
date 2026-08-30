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

Use the guided commands to inspect and change configuration without opening
JSON directly:

```sh
vibeguard-runtime config show --cwd /path/to/project
vibeguard-runtime config init --scope user
vibeguard-runtime config init --scope project --cwd /path/to/project
vibeguard-runtime config set u16.limit 1200 --scope project --cwd /path/to/project
vibeguard-runtime config reset u16.limit --scope project --cwd /path/to/project
```

`show` reports every supported runtime field's effective value, source layer,
category, and description. User scope accepts registered runtime fields.
Project scope also accepts `profile`, `enforcement`, and `languages`.

## Keys

| JSON path | Env var | Default | Effect |
|-----------|---------|---------|--------|
| `u16.warn_limit` | `VG_U16_WARN_LIMIT` | `400` | Source-file typical-size advisory threshold. Files over this and below `u16.limit` warn without blocking. |
| `u16.limit` | `VG_U16_LIMIT` | `800` | Source-file line limit. Files over this trigger block on `Write`/`Edit` and warn after `PostToolUse`. Per-file `CLAUDE.md` exemptions (`U-16 exempt: \`pattern\` → N`) can raise it further per repo. |
| `circuit_breaker.threshold` | `VG_CB_THRESHOLD` | `3` | Consecutive blocks before the hook circuit trips OPEN (silences batch advisories). |
| `circuit_breaker.cooldown_seconds` | `VG_CB_COOLDOWN` | `300` | Seconds an OPEN circuit waits before HALF-OPEN. |
| `circuit_breaker.lock_timeout_seconds` | `VG_CB_LOCK_TIMEOUT_SECONDS` | `5` | Seconds to wait for the circuit-breaker state lock. |
| `w14.cooldown_seconds` | `VIBEGUARD_W14_COOLDOWN_SECONDS` | `3600` | Suppresses repeated W-14 reports for the same directed session pair and file; `0` disables suppression. |
| `churn.informational_edit_count` | `VIBEGUARD_CHURN_INFORMATIONAL_EDIT_COUNT` | `5` | Same-file edit count that starts informational churn guidance; minimum `1`. |
| `churn.warning_edit_count` | `VIBEGUARD_CHURN_WARNING_EDIT_COUNT` | `10` | Same-file edit count that raises churn guidance to warning level; minimum `1`. |
| `churn.critical_edit_count` | `VIBEGUARD_CHURN_CRITICAL_EDIT_COUNT` | `20` | Same-file edit count that enables critical churn classification; minimum `1`. |
| `churn.critical_build_failure_count` | `VIBEGUARD_CHURN_CRITICAL_BUILD_FAILURE_COUNT` | `5` | Consecutive build failures needed with critical churn for escalation; minimum `1`. |
| `w15.minimum_consecutive_edits` | `VIBEGUARD_W15_MINIMUM_CONSECUTIVE_EDITS` | `3` | Minimum same-file trail length, including the current edit. Values above `3` gate on a longer trail while W-15 still compares only the latest three deltas. |
| `w15.latest_delta_character_ceiling` | `VIBEGUARD_W15_LATEST_DELTA_CHARACTER_CEILING` | `300` | Exclusive ceiling for the latest absolute character delta in W-15 micro-tuning detection. |
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
vibeguard-runtime config set u16.limit 1200 --scope user
```

Use `config reset <key> --scope user` to return a user value to lower layers.
Set/reset validates the complete candidate before one atomic replacement and
preserves unrelated valid keys. `setup.sh` seeds this file from
`templates/vibeguard-config.json.example` on first install and never overwrites
your edits afterward. Re-running `setup.sh` is safe.
