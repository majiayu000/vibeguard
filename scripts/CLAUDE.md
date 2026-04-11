# scripts/ directory

Reference notes for the utility scripts shipped with VibeGuard.

## Main scripts

| Script | Purpose |
|------|------|
| `stats.sh` | Analyze `events.jsonl` and summarize hook activity, decision mix, and hot spots |
| `hook-health.sh` | Show recent hook health: risk rate, top noisy hooks, and recent risky events |
| `quality-grader.sh` | Compute the current quality grade from runtime events |
| `project-init.sh` | Bootstrap another repository with detected languages, recommended constraints, and git hook wiring |
| `constraint-recommender.py` | Generate an initial preflight constraint draft from project structure |
| `log-capability-change.sh` | Extract a capability-change timeline from git history |

## GC / Metrics / Verification

| Script | Purpose |
|------|------|
| `gc/gc-logs.sh` | Archive oversized `events.jsonl` logs |
| `gc/gc-worktrees.sh` | Clean up stale worktrees |
| `gc/gc-scheduled.sh` | Scheduled GC + cross-session learning signal aggregation |
| `metrics/metrics-exporter.sh` | Export Prometheus-format metrics from runtime logs |
| `metrics/metrics_collector.sh` | Collect codebase metrics for benchmarking / reporting |
| `verify/compliance_check.sh` | Run project compliance checks |
| `verify/doc-freshness-check.sh` | Cross-check rule IDs against guards/hooks coverage |

## CI helpers (`scripts/ci/`)

| Script | Purpose |
|------|------|
| `validate-guards.sh` | Validate guard script presence, executability, and contract basics |
| `validate-hooks.sh` | Validate hook script presence and contract basics |
| `validate-rules.sh` | Validate rule file format and ID uniqueness |
| `validate-doc-paths.sh` | Check backtick path references in markdown docs |
| `validate-doc-command-paths.sh` | Check `~/vibeguard/...` shell command paths in user-facing docs |
| `validate-no-personal-paths.sh` | Catch accidental personal absolute paths in tracked files |
| `check-branch-protection.sh` | Verify branch protection settings |
| `apply-branch-protection.sh` | Apply the expected branch protection policy |

## Codex integration helpers

| Script | Purpose |
|------|------|
| `codex/app_server_wrapper.py` | External wrapper for `codex app-server` with VibeGuard gates |
| `lib/settings_json.py` | Manage Claude Code hook configuration in `~/.claude/settings.json` |
| `lib/codex_hooks_json.py` | Manage VibeGuard-owned entries in `~/.codex/hooks.json` |
| `setup/` | Install, check, clean, and target-specific setup logic |

## Quick usage

```bash
bash scripts/stats.sh
bash scripts/hook-health.sh 24
bash scripts/quality-grader.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```
