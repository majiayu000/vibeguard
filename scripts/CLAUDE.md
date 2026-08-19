<!-- Generated from docs/directory-guidance.md; do not edit directly. -->

# scripts/ directory

Scripts are grouped by responsibility; search the existing group before adding
a new entrypoint.

| Path | Responsibility |
|------|----------------|
| `setup/` | Public installation, checks, cleanup, and host targets |
| `ci/` | CI and static contract validators |
| `verify/` | Local compliance and freshness checks |
| `gc/` | Log, worktree, and scheduled cleanup |
| `metrics/` | Metrics collection and Prometheus export |
| `release/` | Deterministic release payload construction |
| `constraints/` | Constraint inventory and recommendations |
| `doctors/` | Installation and host diagnostics |
| `lib/` | Shared install and configuration helpers |

Common maintainer entrypoints include `stats.sh`, `health-report.py`,
`hook-health.sh`, `quality-grader.sh`, `project-init.sh`,
`authorized-discard.py`, `live_truth.py`, and `skill_validate.py`. Keep errors
visible, preserve dry-run behavior where documented, and put generated or
session-local output under the ignored locations defined by
`docs/reference/process-artifacts.md`.

The configured hook production path is Rust-first and Python-free. Python
scripts may support tests, CI, evaluation, installation, and maintainer tools,
but must not be introduced into configured hook execution.
