# VibeGuard Command Output Schemas

JSON Schema definition for structured communication between commands. Each command can optionally output JSON format for downstream consumption.

Canonical routing decisions and planning handoffs are defined in `workflows/references/routing-contract.md`. Delegated work assignments are defined in `workflows/references/delegation-contract.md`.

## routing decision Schema

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
    "decision": "execute_direct | plan_first | clarify_first",
    "reason": "Short deterministic explanation",
    "blockingQuestions": [
      "Present only when decision = clarify_first"
    ]
  }
}
```

## execution handoff Schema

```json
{
  "command": "execution_handoff",
  "mode": "fixflow | plan_flow_execution | execplan_execution | auto_optimize | custom",
  "artifacts": [
    "plan/task.md",
    "SPEC.md"
  ],
  "runtime_pinning_snapshot": ".vibeguard/runtime-pinning.snapshot | null",
  "verification_owner": "planner | executor | reviewer | named lane owner",
  "stop_conditions": [
    "Condition that must halt execution"
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
    "Files or directories this worker may modify"
  ],
  "forbidden_files": [
    "Files or directories this worker must not modify"
  ],
  "read_only_files": [
    "Files or directories this worker may inspect but not modify"
  ],
  "authority": "readonly | propose_patch | write_owned_files | verify_only",
  "required_evidence": [
    "Commands, diffs, logs, or findings required for completion"
  ],
  "blocker_conditions": [
    "Conditions that require stopping and escalating"
  ],
  "integration_owner": "single named owner",
  "verification_owner": "owner who runs or accepts checks",
  "handoff_artifacts": [
    "Paths or summaries the worker must return"
  ]
}
```

Delegation assignments are required before any child-agent write lane starts. Parallel work must serialize unless assignment file ownership is disjoint or isolated worktrees are explicitly used.

## preflight output Schema

```json
{
  "command": "preflight",
  "projectType": "rust | typescript | python | go",
  "constraints": [
    {
      "id": "C-01",
      "category": "data_convergence | type_unique | interface_stable | error_handling | naming | guard_baseline",
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
  "date": "ISO8601",
  "guardResults": [
    {
      "guardId": "RS-03",
      "name": "unwrap/expect",
      "count": 50,
      "severity": "medium | high | pass",
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
  "claim_type": "latest | pr-ready | merged | running | deployed | published",
  "verdict": "pass | fail | gap",
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
  "skill_name": "demo-skill",
  "proposed_skill": "path/to/SKILL.md",
  "decision_set": "baseline | held_out",
  "verdict": "pass | fail | stale | needs_justification | advisory",
  "counts": {
    "repair": 1,
    "regression": 0,
    "no_change": 2,
    "unrelated_regression": 0
  },
  "freshness_gaps": [],
  "scenarios": [
    {
      "scenario_id": "incident-1",
      "scenario_type": "target",
      "without_skill": "failure",
      "with_skill": "success",
      "classification": "repair"
    }
  ]
}
```

`scripts/skill_validate.py` appends this artifact as JSONL under `.vibeguard/skill-validate/` unless `--no-persist` is used.

## review output Schema

```json
{
  "command": "review",
  "scope": "File or directory path",
  "findings": [
    {
      "priority": "P0 | P1 | P2 | P3",
      "file": "file_path:line",
      "issue": "Problem description",
      "suggestion": "Repair suggestion",
      "ruleId": "RS-03 | U-11 | ..."
    }
  ],
  "passedItems": [
    "Confirm that there are no problems with the inspection items"
  ],
  "verdict": "pass | warn | fail"
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
      "type": "new_guard | enhance_guard | new_hook | new_rule | claude_md",
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
