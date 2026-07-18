# Hook Latency Contract

VibeGuard hooks run in the critical path of Claude Code and Codex sessions. A correct hook is not acceptable if it turns every agent action into a slow or high-CPU operation.

## Budgets

The benchmark surface is `hook_e2e_ms`: end-to-end hook latency in milliseconds.
It includes shell wrapper/process startup, stdin/stdout handling, config lookup,
event-log access, status/logging work, runtime dispatch, and the hook logic
itself. These numbers are SLA budgets for the installed hook path, not claims
about pure core classifier speed.

Future pure Rust/core classifier microbenchmarks must use the separate
`core_us` surface. `core_us` is reserved for in-process core logic measured in
microseconds and must not include hook wrappers, shell process startup,
stdin/stdout adaptation, config discovery, or logging overhead.

The latency gate measures P50, P95, P99, and max for each benchmark fixture.
An initial P95 budget breach in a healthy environment triggers a second,
fixture-local confirmation batch with the same workload and budget. CI fails
when `--fail-on-regression` is enabled only if the confirmation P95 also
breaches the budget. A confirmation pass is reported as `PASS-CONFIRMED`; it
does not erase the initial tail-latency evidence.

These are cross-OS CI budgets, not ideal-machine optimization targets. Static performance gates still block dangerous patterns before they can hide behind a broad absolute budget.

| Fixture | P95 budget |
|---------|------------|
| `pre-edit-guard` | 300ms |
| `pre-write-guard` | 500ms |
| `pre-bash-guard` | 300ms |
| `post-edit-guard (100)` | 500ms |
| `post-write-guard (100)` | 400ms |
| `post-edit-guard (5000)` | 500ms |
| `post-write-guard (5000)` | 500ms |
| `stop-guard (5000)` | 400ms |
| `learn-evaluator (5000)` | 400ms |
| `codex-wrapper pre-bash-guard` | 900ms |
| `codex-wrapper post-edit-guard (100)` | 900ms |
| `post-build-check (fake cargo)` | 900ms |

Run the gate locally:

```bash
cargo build --manifest-path vibeguard-runtime/Cargo.toml --quiet
bash tests/bench_hook_latency.sh --runs=3 --confirmation-runs=3 --fail-on-regression
```

`--confirmation-runs=<n>` defaults to the initial `--runs=<n>` value and must
be a positive integer. Healthy fixtures do not run the confirmation batch.
Environment-distorted fixtures retain the existing suppressed verdict and do
not fabricate confirmation evidence. Use `--sla=<ms>` only when deliberately
testing a temporary global threshold. The default contract is per-hook.

## Direct vs Wrapper Coverage

Most fixtures invoke hook scripts directly so regressions in hook logic, JSON parsing, logging, and bounded event-log reads are isolated to the hook under test.

Codex wrapper hooks invoke a temporary installed-wrapper copy with the same helper files installed by `scripts/setup/targets/codex-home.sh` and a repo-path file pointing at the repository. These fixtures include Codex event parsing, installed wrapper/helper lookup, runtime policy lookup, status diagnostics, output adaptation, and wrapper finalization before the underlying hook returns. They are intentionally budgeted separately from direct hooks because they measure the installed Codex path, not just the hook body.

Post-build fixtures use fake build commands and disable the post-build cache so CI measures hook overhead, timeout wrapping, project detection, and command dispatch without running a real full build.

## Hotspot Attribution

Benchmark output includes `surface=hook_e2e_ms` and a `hotspot=` field. JSON
output carries the same surface marker at the top level and per result.
The internal JSON's existing top-level per-result `p50`, `p95`, `p99`, `max`,
`status`, and `runs` fields always describe the initial batch. Each result also
records `decision`, an `initial` metrics object, nullable `confirmation`
metrics, and `confirmation_runs`. Decisions are `normal_pass`,
`cleared_transient`, `confirmed_regression`, `environment_distorted`, or
`confirmation_error`.

`bench-output.json` keeps the compact canonical `e2e ... P50/P95/P99` rows as
initial-batch values so historical series do not silently change meaning. A
completed confirmation adds `e2e ... confirmation P95`, `e2e ... budget`, and
a `decision cleared` or `decision confirmed-regression` row. A confirmation
execution error preserves the initial rows, budget, and `decision
confirmation-error`, but does not invent confirmation metrics or a cleared
decision. When a regression fails, the console row must identify both the
surface and fixture size, such as
`surface=hook_e2e_ms ... post-write-guard (5000)`.

Deterministic transient direct/wrapper fixtures, a persistent slow fixture,
and a confirmation execution-error fixture are part of the regression suite:

```bash
bash tests/test_hook_perf_contract.sh
```

That test intentionally runs a slow hook and requires the latency gate to fail, proving the CI gate is not a report-only metric.

## Static Hot Paths

`scripts/ci/validate-hook-perf.sh` blocks dangerous shell patterns in hook scripts:

- Python reading full JSONL logs instead of bounded `tail` input.
- `find` without `-maxdepth` unless a nearby `PERF-OK` comment explains the bounded scope.
- subprocess work inside `for` or `while` loops unless a nearby `PERF-OK` comment explains the cap.

`PERF-OK` is not a blanket bypass. It must state the bound, such as a single file, one-per-session cleanup, an output cap, or `VG_SCAN_MAX_DEFS`.

Run the static gate locally:

```bash
bash scripts/ci/validate-hook-perf.sh
```

## CI Contract

CI runs all three layers:

- `bash scripts/ci/validate-hook-perf.sh`
- `bash tests/test_hook_perf_contract.sh`
- `bash tests/bench_hook_latency.sh --runs=3 --confirmation-runs=3 --fail-on-regression`

If any layer fails, the PR must either make the hook faster or add a precise `PERF-OK` explanation for a bounded case.
