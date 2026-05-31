# Codex Hook Status

VibeGuard keeps hook status separate from model-facing hook feedback.

Use:

```bash
~/.vibeguard/installed/bin/vibeguard-runtime hook-status --mode focused --log-file ~/.vibeguard/events.jsonl
```

The command reads VibeGuard hook JSONL plus optional Codex wrapper diagnostics and reports recent hook results:

- `pass` and `skipped`: visible to the human status surface only.
- `slow`, `running`, `timeout`, and `adapter_error`: visible diagnostics for the user or UI integrations.
- `warn`, `block`, `gate`, `escalate`, and `correction`: actionable model feedback; these are the states that should use `hookSpecificOutput.additionalContext`.

`pass` / `skipped` summaries must not be emitted into `additionalContext` by default. They are useful for clearing stale UI states such as "Running 2 PostToolUse hooks", but they do not require model action and would add avoidable context noise.

JSON mode is intended for UI polling:

```bash
~/.vibeguard/installed/bin/vibeguard-runtime hook-status --json --mode full --log-file ~/.vibeguard/events.jsonl
```

The JSON payload follows `schemas/hook-status.schema.json`. Each entry includes the hook name, event, matcher, normalized status, reason, duration, model-context flag, and log path.

`setup.sh --check` also inspects `~/.codex/hooks.json` for non-Stop hook entries without `timeout`. VibeGuard-managed timeout drift is reported as broken install state. External hooks without timeout, such as an Orca bridge entry, are reported as warnings with the owning command so the user can add a timeout or consult that hook owner.
