# Tech Spec

## Linked Issue

GH-556

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Relevance |
| --- | --- | --- | --- |
| Observe summary | `scripts/stats.sh`, `vibeguard-runtime/src/observe/` | `vibeguard-runtime observe summary` aggregates project/global event logs over days | Source for trigger counts and decision distribution |
| Hook health | `scripts/hook-health.sh`, `vibeguard-runtime/src/observe/render.rs` | `observe health` renders recent attention states and diagnostics | Source for recent risk examples and diagnostics |
| Precision tracker | `scripts/precision-tracker.py`, runtime triage/scorecard files, `data/rule-scorecard.seed.json` | Computes per-rule TP/FP/acceptable precision and lifecycle state | Source for FP risk and rule lifecycle status |
| Triage projection | `hooks/*`, `tests/hooks/test_log_injection.sh` | Guard hits can append unclassified triage rows | Must preserve rule id for GH-555 coverage |
| Session metrics | `vibeguard-runtime/src/session_metrics/engine.rs`, `event_schema.rs` | Emits `hooks`, `tools`, `warn_ratio`, decision metrics | Source for low-cardinality health facts |
| Learn adoption | `scripts/learn/adoption.py`, `~/.vibeguard/learn-adoptions.jsonl` | Records adopted or verified Learn signals | Source for skill/adoption usage evidence |
| Existing weekly infra | `scripts/gc/reflection_digest.py`, `scripts/gc/gc-scheduled.sh` | Produces a separate weekly reflection report | Scheduling pattern, not the health report itself |

## Proposed Design

Add a thin health-report aggregator rather than a new data layer.

1. Create a manual report command, for example `health-report`, with `--days`, `--scope`, `--project`, `--log-file`, `--format markdown|json`, and `--output` options.
2. Read existing structured sources directly or through stable commands:
   - `vibeguard-runtime observe summary --json --days N`
   - `vibeguard-runtime observe health --json --hours N*24`
   - `scripts/precision-tracker.py` helpers or extracted pure functions for triage/scorecard stats
   - `scripts/learn/adoption.py` JSONL records for adopted/verified skill evidence
3. Normalize the report into a small JSON schema, then render markdown from that schema.
4. Keep weekly scheduling opt-in. A later scheduler wrapper may write to `~/.vibeguard/reports/health/YYYY-MM-DD.md`, but only after manual command validation.

## Report Schema

The JSON output should include stable English keys:

```json
{
  "schema_version": 1,
  "window_days": 30,
  "scope": "project",
  "generated_ts": "2026-07-04T00:00:00Z",
  "data_sources": [],
  "overview": {},
  "rule_triggers": [],
  "precision_risks": [],
  "unclassified_backlog": [],
  "idle_assets": {
    "zero_trigger_rules": [],
    "zero_use_skills": []
  },
  "downgrade_candidates": [],
  "follow_up_actions": []
}
```

## Data Rules

- Treat missing event logs as no data, not success-with-zero-risk.
- Treat malformed JSONL, invalid scorecard JSON, or failed child commands as hard errors.
- Keep project and global scopes explicit; never silently mix them.
- Keep rule ids as primary keys. If a candidate lacks a rule id, record it under `unclassified_backlog` with enough source detail for triage.
- Do not mutate the runtime scorecard file during report generation unless the user passes an explicit update flag.

## Product-to-Test Mapping

| Product invariant | Implementation area | Verification |
| --- | --- | --- |
| Manual report exists | `health-report` command or equivalent wrapper | CLI help and sample fixture tests |
| Existing sources reused | observe/precision/adoption readers | Test fixtures cover each source |
| Empty data is visible | report renderer | Fixture with no logs shows no-data state |
| Parse errors fail loudly | source readers | malformed JSONL fixture returns non-zero |
| Decision distribution included | observe summary adapter | markdown and JSON include pass/warn/block counts |
| Downgrade candidates included | rule/skill inventory adapter | 30-day zero-trigger fixture lists candidates |
| Scheduler opt-in only | docs/setup wrapper | no default install side effect |

## Implementation Notes

- Prefer extracting small pure helper functions from `scripts/precision-tracker.py` only when needed; avoid duplicating precision math.
- Use `argparse` and `json` from the Python standard library. Do not add package dependencies.
- Use array-style subprocess calls if a wrapper invokes existing commands.
- Keep output deterministic: sort rules, skills and candidates by id/name.
- Avoid writing into high-context files or installed user config during report generation.

## Dependencies

- GH-554 must land before W-13 reset counts are trustworthy.
- GH-555 must land before W-13 precision and unclassified backlog can be trusted.
- GH-541 can consume the downgrade candidate evidence later, but is not blocked by this spec.

## Test Plan

- Python syntax check for the implemented report command.
- Focused shell test for markdown and JSON output using temporary event, triage, scorecard and adoption fixtures.
- `bash tests/test_stats.sh`
- `bash tests/test_hook_health.sh`
- `bash tests/test_precision_tracker.sh`
- `bash tests/test_learn_adoption.sh`
- `bash scripts/ci/validate-doc-paths.sh`
- `bash scripts/ci/validate-doc-command-paths.sh`

## Rollback Plan

Remove the report command and any opt-in scheduler wrapper. Existing observe, precision tracker, triage, scorecard and Learn adoption files remain unchanged.
