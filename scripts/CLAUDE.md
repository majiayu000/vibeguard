# scripts/ directory

VibeGuard tool script provides statistics, compliance checking, indicator collection and other functions.

## Script description

| Script | Purpose |
|------|------|
| `stats.sh` | Analyze events.jsonl, output hook trigger statistics, warn compliance rate, file type and time period distribution |
| `verify/compliance_check.sh` | Project compliance check, verify compliance with code specifications |
| `metrics/metrics_collector.sh` | Collect project code metrics (number of lines, complexity, etc.) |
| `worktree-guard.sh` | Big change isolation assistance: create/list/merge/delete git worktree |
| `blueprint-runner.sh` | Blueprint orchestrator: read blueprints/*.json, execute deterministic/agent nodes in order |
| `gc/gc-logs.sh` | Log archive: When events.jsonl exceeds 10MB, it will be archived and compressed on a monthly basis and retained for 3 months |
| `gc/gc-worktrees.sh` | Worktree cleanup: delete worktrees that have been inactive for >7 days, only warn about unmerged changes |
| `metrics/metrics-exporter.sh` | Prometheus metric export: generate 4 types of metrics from events.jsonl aggregation |
| `gc/gc-scheduled.sh` | Regular GC + learning + reflection: log archiving, worktree cleaning, metrics cleaning, cross-session learning signal detection, session quality reflection report |
| `project-init.sh` | Project-level scaffolding: detect languages/frameworks → list activation guards/rules → generate CLAUDE.md snippet suggestions and install pre-commit/pre-push hooks |
| `quality-grader.sh` | Quality grade score: calculate A/B/C/D grade from events.jsonl, recommended GC frequency |
| `hook-health.sh` | Hook health snapshot: risk rate in the last N hours, Top risk hooks, Top 10 recent risk events |
| `verify/doc-freshness-check.sh` | Document freshness: cross-check rule ID coverage of rules/ and guards/ |
| `log-capability-change.sh` | Capability evolution log: extract guard/rule/Skill change timeline from git log |
| `constraint-recommender.py` | Constraint recommender: automatically generate the first draft of preflight constraints based on the project language/framework |

## CI scripts (scripts/ci/)

| Script | Purpose |
|------|------|
| `validate-guards.sh` | Verify that all guard scripts are executable and in the correct format |
| `validate-hooks.sh` | Verify that all hook scripts are executable and in the correct format |
| `validate-rules.sh` | Validate rule file format and ID uniqueness |

## Usage

```bash
bash scripts/stats.sh # Statistics for the last 7 days
bash scripts/stats.sh 30 # Last 30 days
bash scripts/stats.sh all # All history
bash scripts/hook-health.sh 24 # Health snapshot of the last 24 hours
```
