# Observability Harness Contract

VibeGuard observability is local-first evidence for hooks, guard behavior, and
eval gates. It answers operational questions from versioned repository scripts
and local JSONL logs before any external telemetry stack is involved.

This contract covers the supported product surface:

- local event logs written by hooks
- session metric rows emitted by the learning/evaluation hook path
- human-facing query commands
- low-cardinality metric labels for future external adapters
- the roadmap for Victoria, Prometheus, and OpenTelemetry integrations

## Storage

VibeGuard writes observability data under the log root selected by
`VIBEGUARD_LOG_DIR`, defaulting to `~/.vibeguard`.

Project scope is the default for human diagnostics inside a git repository:

```text
~/.vibeguard/projects/<project_hash>/events.jsonl
~/.vibeguard/projects/<project_hash>/session-metrics.jsonl
~/.vibeguard/projects/<project_hash>/.project-root
```

Hook event rows are also mirrored to the global aggregate log:

```text
~/.vibeguard/events.jsonl
```

The project hash is derived from the git root path unless an existing
`.project-root` mapping already binds that project to a log directory. Project
scope answers "what happened in this project"; explicit global queries answer
"what happened across my VibeGuard installation." Use `--scope global` for
global diagnostics instead of relying on the default project query path.

## Event Log Contract

`events.jsonl` is the runtime event stream. Each row is one hook or wrapper event
validated by `schemas/event-log.schema.json`.

Required event fields are:

- `schema_version`
- `ts`
- `session`
- `hook`
- `tool`
- `decision`
- `status`

Current rows may also include `event`, `matcher`, `reason`, `detail`, `duration_ms`,
`elapsed_ms`, `timeout_ms`, `model_context`, `log_path`, `source`, and caller
identity fields such as `cli`, `client`, and `wrapper`.

Use this log for:

- recent warnings, blocks, gates, corrections, and adapter errors
- slow hook attribution through duration fields
- project/global scope comparisons
- local evidence before changing rules or hooks

Do not treat `events.jsonl` as an eval-quality result. It records runtime hook
activity; it does not prove that required behavior samples still pass.

## Session Metrics Contract

`session-metrics.jsonl` is the session aggregate stream emitted by
`vibeguard-runtime session-metrics`. Each row is validated by
`schemas/session-metrics.schema.json`.

Required session metric fields are:

- `schema_version`
- `ts`
- `session`
- `event_count`
- `decisions`
- `hooks`
- `tools`
- `top_edited_files`
- `avg_duration_ms`
- `slow_ops`
- `correction_signals`
- `warn_ratio`

Use this file to explain why a session had friction: high warning ratio, repeated
blocks, noisy hooks, slow operations, or concentrated edits. The field
`correction_signals` is an explanatory signal source; it is not a new rule unless
a follow-up rule, guard, hook, or eval is added.

## Query Surfaces

Use the smallest surface that answers the question.

| Question | Surface |
|---|---|
| What happened in this project? | `bash ~/vibeguard/scripts/stats.sh` or `vibeguard-runtime hook-status --mode focused` |
| What happened globally? | `bash ~/vibeguard/scripts/stats.sh --scope global` |
| Why did this session have friction? | `session-metrics.jsonl` and `correction_signals` |
| Which hook is slow? | `vibeguard-runtime hook-status --mode full --slow-ms 2000` or `bash ~/vibeguard/scripts/hook-health.sh 24` |
| Did eval quality regress? | `python3 eval/run_behavior_eval.py --fail-on-threshold` and `python3 eval/summarize_runs.py` |

`docs/reference/codex-hook-status.md` documents the focused hook-status surface.
`docs/reference/hook-latency-contract.md` documents the latency regression gate.
`docs/command-schemas.md` documents the JSON schema references.

Runtime health and eval quality are separate:

- Runtime health asks whether hooks are installed, running, slow, timing out, or
  emitting actionable warn/block/gate states.
- Eval quality asks whether deterministic behavior samples and model-backed rule
  detection still satisfy thresholds.

A healthy runtime can still have an eval regression. A passing eval can still
coexist with a local install problem. Do not collapse these into one verdict.

## Metric Label Contract

External metric labels must be stable, low-cardinality, and non-sensitive.

Allowed default labels:

- `hook`
- `decision`
- `status`
- `tool`
- `cli`
- `client`
- `wrapper`
- `source`
- `schema_version`
- `project_id` as a short opaque hash
- `rule_id` as a bounded rule identifier or `none`
- `reason_code` as a bounded derived reason category
- `severity` as a bounded derived level
- `file_ext` as a bounded derived extension or `none`

Forbidden default labels:

- absolute paths
- usernames or home directories
- raw prompt, model output, or command text
- `session` identifiers
- issue URLs, PR URLs, or branch names
- raw `reason` or `detail`
- stack traces or exception payloads
- file paths from `top_edited_files`
- any secret, token, credential, or account identifier

If a future adapter needs drill-down, it must emit a bounded category such as
`reason_category` or `failure_class`, not raw high-cardinality text. Raw
`reason` and `detail` remain local JSONL diagnostics.

## External Telemetry Boundary

External telemetry is not enabled by default because VibeGuard's first contract
is local evidence without background network egress, credential setup, or
sensitive-label risk. Local logs also preserve deterministic repro data without
depending on a remote collector.

`scripts/metrics/metrics-exporter.sh` is a manual bridge for Prometheus-format
experiments. Do not schedule or enable remote push by default until the emitted
series satisfy the metric label contract above. In particular, raw diagnostic
labels must be removed or reduced to bounded categories before default external
export.

## External Stack Roadmap

External adapters should be added only after the local query layer is stable and
the label contract is enforced in tests.

1. Prometheus textfile adapter: local-only export that uses the allowed label set
   and can be scraped without Pushgateway credentials.
2. VictoriaMetrics adapter: remote-write or scrape-compatible export for hook
   counts, risk rate, slow hook summaries, and eval gate summaries.
3. VictoriaLogs adapter: append-only ingestion for sanitized event rows, with
   raw local logs kept as the source of truth.
4. OpenTelemetry adapter: traces for hook execution spans and optional metrics
   for duration/risk counters, with no prompt or command payload attributes.
5. VictoriaTraces adapter: downstream trace storage once OpenTelemetry spans are
   stable and fixture-backed.

Every adapter must have fixture-backed tests for label allowlisting, sensitive
field rejection, project/global scope behavior, and disabled-by-default startup.

## Verification

Run the documentation validators after changing this contract:

```bash
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```

Run the observability schema test when event or session metric fields change:

```bash
bash tests/test_observability_schemas.sh
```
