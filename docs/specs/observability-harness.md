# Spec: VibeGuard observability harness

- Status: Draft
- Date: 2026-06-05
- Owner: @majiayu000
- Issues: #394, #395, #396, #397, #398, #399, #400
- Readiness: plan_first
- Severity: P1
- Suggested labels: `observability`, `P1`, `runtime`, `eval`, `dx`
- Related: `hooks/log.sh`, `hooks/_lib/log_write.sh`, `vibeguard-runtime/src/event_schema.rs`, `vibeguard-runtime/src/session_metrics/`, `vibeguard-runtime/src/hook_status.rs`, `scripts/hook-health.sh`, `scripts/stats.sh`, `scripts/quality-grader.sh`, `scripts/metrics/metrics-exporter.sh`, `eval/`, `docs/reference/harness-engineering.md`

## Problem

VibeGuard already records hook activity, session metrics, behavior eval artifacts,
precision data, and latency benchmark results. The missing layer is a coherent
observability harness that turns those separate surfaces into one queryable,
low-cardinality, scope-aware system.

Current gaps:

- Runtime logs are split between project logs and the global log, but report
  scripts default to the global log. This makes current-project diagnosis noisy
  when the same user has many VibeGuard-enabled repositories.
- Event fields are partially canonical in Rust constants, but there is no JSON
  Schema contract for event logs or session metrics.
- Report scripts duplicate JSONL parsing and aggregation in shell/Python even
  though `vibeguard-runtime` is already the canonical hot-path runtime.
- Prometheus export currently labels by raw `reason`, which creates high-cardinality
  metrics for values like file-size warnings.
- Runtime health, hook latency, behavior eval pass rate, model-backed detection
  rate, false positive rate, and precision tracker results are not exposed through
  one stable command surface.
- Eval artifacts are persisted per run, but there is no small index that lets
  maintainers compare recent runs without opening every `eval/runs/*/results.json`.
- Harness observability principles are documented, but not yet converted into
  executable VibeGuard contracts.

## Verified facts

- `hooks/_lib/log_write.sh` writes event JSONL with `schema_version`, `ts`,
  `session`, `hook`, `tool`, `decision`, `reason`, `detail`, optional
  `duration_ms`, and caller identity fields.
- `hooks/log.sh` writes both a per-project log under
  `~/.vibeguard/projects/<hash>/events.jsonl` and a global
  `~/.vibeguard/events.jsonl`.
- `vibeguard-runtime/src/event_schema.rs` defines canonical Rust constants for
  event fields, decisions, status values, tools, and session metric fields.
- `vibeguard-runtime session-metrics` writes project-level
  `session-metrics.jsonl` with `schema_version`, `event_count`, decision counts,
  hook counts, tool counts, `avg_duration_ms`, `slow_ops`, `warn_ratio`, and
  `correction_signals`.
- `vibeguard-runtime hook-status --json` already exposes a JSON status surface
  for UI polling and separates human status from model-facing hook feedback.
- `scripts/metrics/metrics-exporter.sh` exports Prometheus text metrics from
  `events.jsonl`, but includes `reason` as a metric label.
- `eval/run_behavior_eval.py` produces deterministic behavior reports with
  pass rate, coverage, slice failures, and artifact paths.
- `eval/run_eval.py` produces model-backed judge reports with detection rate,
  false positive rate, skipped infrastructure errors, latency, and calibration.
- `docs/reference/hook-latency-contract.md` already defines per-hook P95 budgets
  and latency verification commands.

## Goals

- G1: Define stable schemas for runtime event logs, session metrics, observe
  command output, and eval summary records.
- G2: Make project-scoped observability the default for diagnosis, while keeping
  global/cross-project views explicit and available.
- G3: Add a canonical Rust `vibeguard-runtime observe` command family for
  summary, health, session explanation, and export.
- G4: Keep hook hot paths thin: hooks continue to call `vg_log`; aggregation and
  querying move to the runtime.
- G5: Export low-cardinality metrics suitable for Prometheus/Victoria Metrics
  without leaking raw commands, paths, or full reasons as labels.
- G6: Keep runtime health and quality evaluation separate. Runtime health answers
  "is the harness operating well"; eval quality answers "are rules/hooks catching
  the right behavior".
- G7: Preserve the current model-context contract: pass/skipped summaries remain
  human/UI-only and do not add model context noise.
- G8: Provide issue-sized implementation slices with focused verification
  commands.

## Non-goals

- Do not deploy Victoria Logs, Victoria Metrics, Victoria Traces, OpenTelemetry,
  or a dashboard in the first implementation wave.
- Do not change hook enforcement semantics or decision meanings.
- Do not replace `events.jsonl` as the source of record.
- Do not send telemetry over the network by default.
- Do not add raw command text, full file paths, raw reasons, or details as metric
  labels.
- Do not merge deterministic behavior eval scores with model-backed judge scores
  into one opaque score.
- Do not rewrite unrelated setup, install, or hook policy behavior.

## Design

### 1. Observability layers

Use four layers, each with a clear contract:

1. Collection: hook scripts call `vg_log`, producing append-only JSONL.
2. Runtime query: `vibeguard-runtime observe` reads bounded event and metric logs.
3. Export: Prometheus text or JSON output generated from runtime query results.
4. Feedback: learn/gc/eval summaries consume runtime query outputs rather than
   reimplementing log parsing.

The first implementation should stay local-first. External observability stacks
can consume the export surface later.

### 2. Event log schema

Add a future schema file named schemas/event-log.schema.json for `events.jsonl`.

Required fields:

- `schema_version`
- `ts`
- `session`
- `hook`
- `tool`
- `decision`
- `reason`
- `detail`

Optional existing fields:

- `duration_ms`
- `cli`
- `agent`
- `client`
- `client_variant`
- `wrapper`
- `source_config`
- `hook_protocol_version`
- `caller_evidence`

Optional normalized fields to add over time:

- `project_hash`: first 8 characters of the project root SHA-256.
- `project_root_hash`: redacted stable hash of the project root path.
- `event`: hook protocol event such as `PreToolUse`, `PostToolUse`, or `Stop`.
- `matcher`: hook matcher such as `Bash`, `Edit`, `Write`, or `<none>`.
- `rule_id`: extracted rule identifier such as `U-16`, `RS-03`, `L1`, or
  `unknown`.
- `reason_code`: stable low-cardinality reason identifier such as
  `file_size_advisory`, `build_timeout`, `new_source_file`, `duplicate_definition`,
  `dangerous_command`, `malformed_input`, or `unknown`.
- `severity`: normalized impact class: `info`, `advisory`, `review`, `block`,
  `critical`, or `unknown`.
- `profile`: active VibeGuard profile when known.
- `file_ext`: file extension only, never a full path.

Compatibility rule: existing readers must tolerate missing optional normalized
fields. New aggregators should prefer normalized fields when present and fall
back to safe extraction from `reason` or `detail`.

### 3. Session metrics schema

Add a future schema file named schemas/session-metrics.schema.json for
`session-metrics.jsonl`.

Required fields should mirror the current runtime output:

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

Add optional future fields:

- `project_hash`
- `duration_p50_ms`
- `duration_p95_ms`
- `duration_p99_ms`
- `attention_count`
- `model_context_count`
- `timeout_count`
- `hook_error_count`

Do not change existing session metric semantics in the schema issue. Percentile
fields can be added in the observe command issue if the raw event stream has
enough samples.

### 4. Scope model

Every observe command should accept:

```text
--scope project|global
--project <path-or-hash>
--log-file <path>
--since <duration>
--json
```

Default behavior:

- In a git repository: `--scope project`, resolved from `git rev-parse --show-toplevel`.
- Outside a git repository: `--scope global`.
- `--log-file` overrides scope resolution for tests and diagnostics.

Scope resolution should be centralized in Rust so scripts do not independently
recompute log paths.

### 5. Runtime observe command

Add a `vibeguard-runtime observe` command family.

Initial subcommands:

```text
vibeguard-runtime observe summary [--scope project|global] [--since 24h] [--json]
vibeguard-runtime observe health [--scope project|global] [--since 24h] [--json]
vibeguard-runtime observe session <session-id> [--json]
vibeguard-runtime observe export prometheus [--scope project|global] [--since 7d]
```

`summary` should report:

- time range
- event count
- decision counts
- risk/attention count and rate
- hook counts
- client distribution
- top normalized rule IDs
- top normalized reason codes
- top file extensions
- average duration and p95 duration by hook when available

`health` should report:

- latest attention events
- slow hooks
- timeout and hook error states
- running/adapter diagnostics when available from the hook-status diagnostic log
- whether the active view is project or global

`session` should explain:

- session timeline summary
- decision mix
- top hooks/tools
- correction signals
- repeated rule or file patterns
- slow operations
- recent attention events

`export prometheus` should replace or wrap `scripts/metrics/metrics-exporter.sh`
without changing the public command immediately.

### 6. Low-cardinality metric contract

Prometheus labels allowed in first wave:

- `scope`
- `project_hash`
- `hook`
- `tool`
- `decision`
- `client`
- `rule_id`
- `reason_code`
- `severity`
- `file_ext`

Prometheus labels forbidden:

- raw `reason`
- raw `detail`
- full file path
- command text
- session ID by default
- agent free-form name by default

Initial metrics:

```text
vibeguard_events_total{scope,project_hash,hook,decision,client}
vibeguard_attention_events_total{scope,project_hash,hook,decision,rule_id,reason_code,severity}
vibeguard_hook_duration_seconds_bucket{scope,project_hash,hook,le}
vibeguard_hook_duration_seconds_sum{scope,project_hash,hook}
vibeguard_hook_duration_seconds_count{scope,project_hash,hook}
vibeguard_session_friction_ratio{scope,project_hash}
vibeguard_session_slow_ops_total{scope,project_hash}
vibeguard_eval_behavior_pass_rate{dataset_digest,commit}
vibeguard_eval_behavior_coverage_rate{dataset_digest,commit}
vibeguard_eval_model_detection_rate{model,rule_prefix,rule_digest,dataset_digest}
vibeguard_eval_model_false_positive_rate{model,rule_prefix,rule_digest,dataset_digest}
```

Eval metrics should be generated from eval summary artifacts, not from live hook
logs.

### 7. Eval observability

Add an eval summary index generated from existing run artifacts.

Proposed generated path:

```text
eval/runs/index.jsonl
```

Record shape:

```json
{
  "schema_version": 1,
  "ts": "2026-06-05T00:00:00Z",
  "kind": "behavior|model",
  "artifact_path": "eval/runs/20260605T000000Z-abcdef/results.json",
  "commit": "full git sha",
  "dataset_source": "eval/behavior/datasets/v1.jsonl",
  "dataset_digest": "sha256",
  "sample_count": 0,
  "verdict": "pass|fail|unknown",
  "pass_rate": 100.0,
  "coverage_rate": 100.0,
  "slice_failures": 0,
  "model": "claude-haiku-4-5-20251001",
  "detection_rate": 0.0,
  "false_positive_rate": 0.0,
  "skipped_count": 0,
  "ece": 0.0,
  "latency_seconds": 0.0
}
```

Rules:

- Deterministic behavior eval and model-backed judge eval must stay labeled by
  `kind`.
- Skipped model samples are infrastructure failures, not false positives or
  missed detections.
- Any command that compares runs must display dataset digest, rule digest, model,
  and commit.

### 8. Migration of existing scripts

Keep the current user-facing scripts, but migrate them to call runtime observe
commands internally:

- `scripts/hook-health.sh` -> `vibeguard-runtime observe health`
- `scripts/stats.sh` -> `vibeguard-runtime observe summary`
- `scripts/metrics/metrics-exporter.sh` -> `vibeguard-runtime observe export prometheus`
- `scripts/quality-grader.sh` can remain separate initially because it combines
  runtime events with rule coverage and installed native rule visibility.

Each wrapper should support `--scope` and `--log-file` for tests.

### 9. Harness alignment

This design intentionally mirrors the harness guidance already documented in
`docs/reference/harness-engineering.md`:

- local observable stack first
- queryable API
- per-worktree or per-project isolation
- performance constraints as executable checks
- repository artifacts as the system of record

The first VibeGuard implementation uses JSONL and CLI queries instead of
standing up Victoria Logs/Metrics/Traces. That keeps the manual phase small and
validated before automation.

## Acceptance criteria

- AC1: Event log and session metrics schemas exist and validate representative
  fixtures with valid, malformed, and legacy rows.
- AC2: A current-repository diagnosis defaults to project scope and does not mix
  unrelated project events unless `--scope global` is explicit.
- AC3: `vibeguard-runtime observe summary --json` returns a schema-versioned JSON
  payload with counts, attention rate, hook distribution, client distribution,
  and duration statistics.
- AC4: `vibeguard-runtime observe health --json` preserves the hook-status
  model-context boundary: pass/skipped entries are not presented as actionable
  model feedback.
- AC5: Prometheus export contains no raw `reason`, raw `detail`, full path,
  command text, or session ID labels.
- AC6: Existing `hook-health`, `stats`, and metrics exporter tests still pass
  after wrapper migration.
- AC7: Behavior eval and model-backed eval summaries can be compared across at
  least two run artifacts without opening individual result files manually.
- AC8: Hook latency gates still pass and identify hook/fixture hotspots.
- AC9: Documentation names the scope behavior, metric label contract, and eval
  score separation.

## Verification

Run these commands before closing the full spec:

```bash
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash tests/test_hook_status.sh
bash tests/test_hook_health.sh
bash tests/test_stats.sh
bash tests/test_quality_grader.sh
bash tests/test_behavior_eval.sh
bash tests/test_hook_perf_contract.sh
bash tests/bench_hook_latency.sh --runs=3 --fail-on-regression
bash scripts/ci/validate-hook-perf.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```

Focused issues may run a smaller subset, but every issue must name its focused
verification commands.

## Work breakdown (issue drafts)

### Issue 1: Add event-log and session-metrics schema contracts

Issue: https://github.com/majiayu000/vibeguard/issues/394

Labels: `observability`, `schema`, `P1`, `tests`

Problem:

Runtime JSONL logs and session metrics are canonical data sources, but they do
not have JSON Schema contracts. Rust readers use field constants, while scripts
and docs still infer shapes independently.

Proposed solution:

- Add a schema file named schemas/event-log.schema.json.
- Add a schema file named schemas/session-metrics.schema.json.
- Add fixtures for current rows, legacy rows without optional normalized fields,
  malformed JSON, and malformed UTF-8 recovery expectations.
- Add a focused validation test.
- Document that normalized fields are optional in schema v1.

Acceptance criteria:

- Valid current `events.jsonl` rows pass schema validation.
- Legacy rows without normalized fields pass schema validation.
- Invalid decision/status values fail schema validation.
- Current session metrics rows pass schema validation.
- Schema tests tolerate broken JSONL by skipping invalid rows only where the
  reader contract explicitly permits it.

Verification:

```bash
bash tests/test_hook_status.sh
bash tests/test_hook_health.sh
bash tests/test_stats.sh
bash scripts/ci/validate-doc-paths.sh
```

### Issue 2: Make observability scope explicit and default to project diagnosis

Issue: https://github.com/majiayu000/vibeguard/issues/395

Labels: `observability`, `dx`, `P1`, `runtime`

Problem:

Project logs and global logs both exist, but user-facing diagnosis scripts
default to the global log. This mixes unrelated repositories and makes hook
health noisy.

Proposed solution:

- Add a Rust log-scope resolver for `project`, `global`, and explicit
  `--log-file`.
- Resolve current project via `git rev-parse --show-toplevel` when available.
- Add `--scope project|global`, `--project <path-or-hash>`, and `--log-file`
  support to observe commands.
- Update wrapper scripts to expose `--scope` and preserve test overrides.
- Document project/global behavior.

Acceptance criteria:

- In a git repository, observe defaults to the matching project log.
- `--scope global` reads `~/.vibeguard/events.jsonl`.
- `--log-file` wins over scope resolution.
- Missing project log produces a clear no-data message, not a global fallback.
- Tests cover project, global, missing, and explicit log-file cases.

Verification:

```bash
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash tests/test_hook_health.sh
bash tests/test_stats.sh
```

### Issue 3: Add `vibeguard-runtime observe summary|health|session`

Issue: https://github.com/majiayu000/vibeguard/issues/396

Labels: `observability`, `runtime`, `P1`, `cli`

Problem:

Hook diagnosis is split across `hook-status`, `hook-health.sh`, `stats.sh`,
session metrics, and GC scripts. There is no canonical query command that can
answer current health, session explanation, and project summary from the same
reader.

Proposed solution:

- Add `vibeguard-runtime observe summary`.
- Add `vibeguard-runtime observe health`.
- Add `vibeguard-runtime observe session <session-id>`.
- Support human and `--json` output.
- Add a schema file named schemas/observe-output.schema.json if the JSON payload is shared across
  UI or scripts.
- Reuse `event_schema` constants and bounded/tolerant JSONL reading.

Acceptance criteria:

- `summary --json` reports time range, event counts, decision counts, hook
  counts, client distribution, attention rate, top rule IDs, top reason codes,
  and duration stats.
- `health --json` reports recent attention states and slow/timeout/hook-error
  diagnostics without turning pass/skipped into model feedback.
- `session <id> --json` explains one session without including other sessions.
- Human output stays concise and actionable.
- Malformed JSONL does not crash the command.

Verification:

```bash
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash tests/test_hook_status.sh
```

### Issue 4: Replace high-cardinality Prometheus export with observe export

Issue: https://github.com/majiayu000/vibeguard/issues/397

Labels: `observability`, `metrics`, `P1`, `security`

Problem:

The current Prometheus exporter labels metrics by raw `reason`, which creates
high-cardinality metrics and can expose sensitive or overly specific user data.

Proposed solution:

- Add `vibeguard-runtime observe export prometheus`.
- Emit only the allowed low-cardinality labels from this spec.
- Derive `rule_id`, `reason_code`, `severity`, and `file_ext` safely.
- Keep `scripts/metrics/metrics-exporter.sh` as a compatibility wrapper.
- Add regression tests proving raw reason/detail/path/command/session labels are
  absent.

Acceptance criteria:

- Prometheus output includes event counters and duration histograms or summaries.
- No metric label contains raw `reason`, raw `detail`, full path, command text,
  or session ID by default.
- Existing exporter invocation still works.
- Export supports `--scope project|global`, `--since`, and `--file`.

Verification:

```bash
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash tests/test_hook_health.sh
bash tests/test_stats.sh
bash scripts/ci/validate-hook-perf.sh
```

### Issue 5: Add eval run index and eval observability summary

Issue: https://github.com/majiayu000/vibeguard/issues/398

Labels: `observability`, `eval`, `P2`, `tests`

Problem:

Eval runs persist full artifacts, but maintainers cannot quickly compare recent
behavior eval and model-backed eval results without opening each run directory.

Proposed solution:

- Add an eval summary index writer for `eval/runs/index.jsonl`.
- Add a schema file named schemas/eval-run-summary.schema.json.
- Extend or wrap `eval/run_behavior_eval.py` and `eval/run_eval.py` so each run
  appends a summary record.
- Add a read-only command such as `python3 eval/summarize_runs.py --last 10`.
- Keep deterministic behavior results and model-backed judge results separated
  by `kind`.

Acceptance criteria:

- Behavior eval appends `kind=behavior` summary records with pass rate, coverage
  rate, slice failures, dataset digest, and commit.
- Model-backed eval appends `kind=model` summary records with detection rate,
  false positive rate, skipped count, ECE when available, model, rule digest,
  dataset digest, and commit.
- Summary comparison displays enough metadata to detect overfitting or mixed
  deterministic/probabilistic scores.
- Existing eval tests still pass.

Verification:

```bash
bash tests/test_behavior_eval.sh
python3 -m py_compile eval/run_eval.py eval/run_behavior_eval.py
```

### Issue 6: Migrate stats and health wrappers to the canonical observe reader

Issue: https://github.com/majiayu000/vibeguard/issues/399

Labels: `observability`, `runtime`, `P2`, `refactor`

Problem:

`hook-health.sh`, `stats.sh`, and metrics export duplicate event parsing and
aggregation. This duplicates malformed-input handling and makes future schema
changes harder.

Proposed solution:

- Convert `scripts/hook-health.sh` to call `vibeguard-runtime observe health`.
- Convert `scripts/stats.sh` to call `vibeguard-runtime observe summary`.
- Convert `scripts/metrics/metrics-exporter.sh` to call
  `vibeguard-runtime observe export prometheus`.
- Preserve existing command output where tests depend on it, or update tests only
  for intentional output contract changes.
- Keep script wrappers thin for user compatibility.

Acceptance criteria:

- Wrapper scripts contain no independent JSONL aggregation logic.
- Existing malformed UTF-8 and broken JSONL tests remain green.
- Existing no-data and invalid-argument messages remain clear.
- Wrapper scripts support project/global scope.

Verification:

```bash
bash tests/test_hook_health.sh
bash tests/test_stats.sh
bash tests/test_quality_grader.sh
bash scripts/ci/validate-hook-perf.sh
```

### Issue 7: Document observability harness contract and external-stack roadmap

Issue: https://github.com/majiayu000/vibeguard/issues/400

Labels: `observability`, `documentation`, `P2`

Problem:

Harness observability principles are documented as reference material, but
VibeGuard lacks a product-level contract that explains local observability,
metric labels, project/global scope, and the path to external stacks.

Proposed solution:

- Add or update a public reference doc for the observability harness.
- Document `events.jsonl`, `session-metrics.jsonl`, observe commands, scope
  behavior, and the metric label contract.
- Document why external telemetry is not enabled by default.
- Add a roadmap section for Victoria/Prometheus/OpenTelemetry adapters after the
  local query layer is stable.
- Link the doc from `docs/directory-map.md` or another appropriate docs index if
  needed.

Acceptance criteria:

- Docs explain how to answer "what happened in this project", "why did this
  session have friction", "which hook is slow", and "did eval quality regress".
- Docs explicitly forbid high-cardinality/sensitive metric labels.
- Docs distinguish runtime health from eval quality.
- Documentation validators pass.

Verification:

```bash
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```

## Routing handoff

```yaml
handoff:
  mode: fixflow
  artifacts:
    - docs/specs/observability-harness.md
  runtime_pinning_snapshot: None
  verification_owner: implementation owner
  stop_conditions:
    - Any issue requires changing hook decision semantics.
    - Any issue proposes network telemetry by default.
    - Metrics export needs raw reason/detail/path/session labels.
    - Scope migration would silently fall back from missing project logs to global logs.
  lane_map:
    schemas: implementation owner
    runtime_observe: implementation owner
    script_wrappers: implementation owner
    eval_observability: implementation owner
    docs: implementation owner
```
