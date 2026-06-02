# VibeGuard Command Output Schemas

JSON Schema definition for structured communication between commands. Each command can optionally output JSON format for downstream consumption.

Canonical routing decisions and planning handoffs are defined in `workflows/references/routing-contract.md`. Delegated work assignments are defined in `workflows/references/delegation-contract.md`.

Executable schema sources:

- `schemas/command-preflight-output.schema.json`
- `schemas/command-check-output.schema.json`
- `schemas/command-live-truth-output.schema.json`
- `schemas/command-skill-validate-output.schema.json`
- `schemas/command-review-output.schema.json`
- `schemas/command-learn-output.schema.json`
- `schemas/workflow-routing-decision.schema.json`
- `schemas/workflow-execution-handoff.schema.json`
- `schemas/workflow-delegation-assignment.schema.json`
- `schemas/workflow-lane-map.schema.json`
- `schemas/workflow-verification-gate.schema.json`

## routing decision Schema

Allowed `readiness.decision` values are `execute_direct`, `plan_first`, and `clarify_first`.

```json
{
  "command": "routing_decision",
  "precedence": [
    "user_override",
    "risk_destructive_gate",
    "ambiguity_gate",
    "readiness_classifier",
    "execution_or_delegation_lane"
  ],
  "readiness": {
    "decision": "execute_direct",
    "reason": "Task is bounded, ownership is clear, and verification can run immediately"
  }
}
```

## execution handoff Schema

```json
{
  "command": "execution_handoff",
  "mode": "fixflow",
  "artifacts": [
    "plan/task.md"
  ],
  "runtime_pinning_snapshot": null,
  "verification_owner": "executor",
  "stop_conditions": [
    "Stop if a required check cannot run"
  ],
  "lane_map": {
    "implementation": "fixflow",
    "verification": "reviewer"
  }
}
```

Required handoff keys:

- `mode`
- `artifacts`
- `runtime_pinning_snapshot`
- `verification_owner`
- `stop_conditions`
- `lane_map`

## delegation assignment Schema

```json
{
  "command": "delegation_assignment",
  "task_slice": "Specific bounded outcome",
  "allowed_files": [
    "src/owned-module"
  ],
  "forbidden_files": [
    "AGENTS.md"
  ],
  "read_only_files": [
    "workflows/references"
  ],
  "authority": "write_owned_files",
  "required_evidence": [
    "Focused test output"
  ],
  "blocker_conditions": [
    "Unexpected edits outside allowed_files"
  ],
  "integration_owner": "single named owner",
  "verification_owner": "owner who runs or accepts checks",
  "handoff_artifacts": [
    "Paths or summaries the worker must return"
  ]
}
```

Delegation assignments are required before any child-agent write lane starts. Parallel work must serialize unless assignment file ownership is disjoint or isolated worktrees are explicitly used.

## lane map ownership Schema

```json
{
  "implementation": "fixflow",
  "verification": "reviewer"
}
```

## verification gate Schema

```json
{
  "verification_owner": "executor",
  "stop_conditions": [
    "Stop if a required check cannot run"
  ],
  "required_checks": [
    "bash tests/test_manifest_contract.sh"
  ]
}
```

## preflight output Schema

```json
{
  "command": "preflight",
  "projectType": "rust",
  "constraints": [
    {
      "id": "C-01",
      "category": "data_convergence",
      "description": "Constraint description",
      "source": "source evidence",
      "verification": "verification method"
    }
  ],
  "guardBaseline": {
    "unwrap": 50,
    "duplicateTypes": 2,
    "nestedLocks": 0,
    "workspaceConsistency": 0
  },
  "unclear": [
    {
      "id": "UNCLEAR-01",
      "question": "Question requiring confirmation",
      "options": ["option A", "option B"]
    }
  ]
}
```

## check output Schema

```json
{
  "command": "check",
  "project": "project name",
  "date": "2026-05-31T00:00:00Z",
  "guardResults": [
    {
      "guardId": "RS-03",
      "name": "unwrap/expect",
      "count": 50,
      "severity": "medium",
      "details": ["file:line description"]
    }
  ],
  "complianceScore": 6.5,
  "baselineComparison": {
    "unwrap": { "before": 50, "after": 48, "delta": -2 },
    "duplicateTypes": { "before": 2, "after": 2, "delta": 0 }
  }
}
```

## live_truth output Schema

```json
{
  "command": "live_truth",
  "claim_type": "latest",
  "verdict": "gap",
  "facts": [
    {
      "key": "active_branch",
      "value": "main"
    }
  ],
  "inferences": [
    "local branch contains the fetched origin/main ref"
  ],
  "unresolved_gaps": [
    "worktree has uncommitted changes"
  ]
}
```

The text artifact emitted by `scripts/live_truth.py` uses these same sections so final answers and PR comments do not mix facts with assumptions.

## skill_validate output Schema

```json
{
  "command": "skill_validate",
  "mode": "evidence",
  "skill_name": "demo-skill",
  "proposed_skill": "path/to/SKILL.md",
  "decision_set": "baseline",
  "verdict": "pass",
  "counts": {
    "repair": 1,
    "regression": 0,
    "no_change": 2,
    "unrelated_regression": 0,
    "unrelated_no_change": 2
  },
  "freshness_gaps": [],
  "reasons": [
    "repair count is greater than regression count with no regressions"
  ],
  "regression_justification": null,
  "scored_against_agent": "claude-opus-4-7",
  "scored_at": "2026-05-31",
  "scenarios": [
    {
      "scenario_id": "incident-1",
      "scenario_type": "target",
      "without_skill": "failure",
      "with_skill": "success",
      "classification": "repair",
      "source": "baseline",
      "scored_against_agent": "claude-opus-4-7",
      "scored_at": "2026-05-31",
      "notes": null
    }
  ]
}
```

`scripts/skill_validate.py` appends this artifact as JSONL under `.vibeguard/skill-validate/` unless `--no-persist` is used.
Evidence validation also fails when the proposed `SKILL.md` is missing the required reusable-skill sections: `## When to Activate`, `## Red Flags`, and `## Checklist`.

## skill_validate format output Schema

```json
{
  "command": "skill_validate",
  "mode": "format",
  "verdict": "pass",
  "paths_checked": 1,
  "required_sections": [
    "## When to Activate",
    "## Red Flags",
    "## Checklist"
  ],
  "list_required_sections": [
    "## Red Flags",
    "## Checklist"
  ],
  "errors": []
}
```

Format-only checks use the same command surface. Add `--json` when another tool needs the schema-compatible artifact:

```bash
python3 scripts/skill_validate.py --format-only --proposed-skill path/to/SKILL.md --json
python3 scripts/skill_validate.py --check-repo-format --repo-root . --json
```

`--check-repo-format` scans `skills/*/SKILL.md`, `workflows/*/SKILL.md`, and `templates/skill-template.md`.

## review output Schema

```json
{
  "command": "review",
  "scope": "File or directory path",
  "findings": [
    {
      "priority": "P2",
      "file": "file_path:line",
      "issue": "Problem description",
      "suggestion": "Repair suggestion",
      "ruleId": "U-11"
    }
  ],
  "passedItems": [
    "Confirm that there are no problems with the inspection items"
  ],
  "verdict": "warn"
}
```

## learn output Schema

```json
{
  "command": "learn",
  "error": "Error description",
  "rootCause": {
    "surface": "surface reason",
    "direct": "direct cause",
    "root": "root cause"
  },
  "improvements": [
    {
      "type": "enhance_guard",
      "target": "target file path",
      "description": "Improve description"
    }
  ],
  "verification": {
    "newGuardPassed": true,
    "noRegression": true
  }
}
```
