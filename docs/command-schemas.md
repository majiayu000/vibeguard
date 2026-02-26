# VibeGuard Command Output Schemas

命令间结构化通信的 JSON Schema 定义。各命令可选择输出 JSON 格式以便下游消费。

## preflight 输出 Schema

```json
{
  "command": "preflight",
  "projectType": "rust | typescript | python | go",
  "constraints": [
    {
      "id": "C-01",
      "category": "data_convergence | type_unique | interface_stable | error_handling | naming | guard_baseline",
      "description": "约束描述",
      "source": "来源证据",
      "verification": "验证方法"
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
      "question": "需要确认的问题",
      "options": ["选项A", "选项B"]
    }
  ]
}
```

## check 输出 Schema

```json
{
  "command": "check",
  "project": "项目名",
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

## review 输出 Schema

```json
{
  "command": "review",
  "scope": "文件或目录路径",
  "findings": [
    {
      "priority": "P0 | P1 | P2 | P3",
      "file": "file_path:line",
      "issue": "问题描述",
      "suggestion": "修复建议",
      "ruleId": "RS-03 | U-11 | ..."
    }
  ],
  "passedItems": [
    "确认无问题的检查项"
  ],
  "verdict": "pass | warn | fail"
}
```

## learn 输出 Schema

```json
{
  "command": "learn",
  "error": "错误描述",
  "rootCause": {
    "surface": "表面原因",
    "direct": "直接原因",
    "root": "根本原因"
  },
  "improvements": [
    {
      "type": "new_guard | enhance_guard | new_hook | new_rule | claude_md",
      "target": "目标文件路径",
      "description": "改进描述"
    }
  ],
  "verification": {
    "newGuardPassed": true,
    "noRegression": true
  }
}
```
