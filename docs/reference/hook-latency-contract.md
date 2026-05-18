# Hook Latency Contract

VibeGuard hooks run in the critical path of Claude Code and Codex sessions. A correct hook is not acceptable if it turns every agent action into a slow or high-CPU operation.

## Budgets

The latency gate measures P50, P95, P99, and max for each benchmark fixture. CI fails when `--fail-on-regression` is enabled and any fixture exceeds its P95 budget.

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

Run the gate locally:

```bash
bash tests/bench_hook_latency.sh --runs=3 --fail-on-regression
```

Use `--sla=<ms>` only when deliberately testing a temporary global threshold. The default contract is per-hook.

## Hotspot Attribution

Benchmark output includes a `hotspot=` field and `bench-output.json` publishes P95/P99 samples for GitHub benchmark reporting. When a regression fails, the failing row must identify both the hook and fixture size, such as `post-write-guard (5000)`.

Synthetic slow fixtures are part of the regression suite:

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
- `bash tests/bench_hook_latency.sh --runs=3 --fail-on-regression`

If any layer fails, the PR must either make the hook faster or add a precise `PERF-OK` explanation for a bounded case.
