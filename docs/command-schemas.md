# VibeGuard Command Output Schemas

JSON Schema definition for structured communication between commands. Each command can optionally output JSON format for downstream consumption.

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
