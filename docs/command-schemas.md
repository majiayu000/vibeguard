# VibeGuard Command Output Schemas

JSON Schema definition for structured communication between commands. Each command can optionally output JSON format for downstream consumption.

Canonical routing decisions and planning handoffs are defined in `workflows/references/routing-contract.md`.
Delegated lane assignment and reintegration are defined in `workflows/references/delegation-contract.md`.

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
  "lane": "docs | tests | implementation | custom",
  "task_slice": "Bounded objective for this lane",
  "allowed_files": [
    "paths or globs this lane may read/write"
  ],
  "forbidden_files": [
    "paths or globs this lane must not modify"
  ],
  "authority": "readonly | propose_patch | write_patch | verify_only",
  "required_evidence": [
    "commands, logs, screenshots, or diff evidence required from this lane"
  ],
  "blocker_conditions": [
    "conditions that stop this lane and escalate to the leader"
  ],
  "integration_owner": "single owner who merges or rejects this lane"
}
```

Required delegation assignment keys:

- `task_slice`
- `allowed_files`
- `forbidden_files`
- `authority`
- `required_evidence`
- `blocker_conditions`
- `integration_owner`

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
