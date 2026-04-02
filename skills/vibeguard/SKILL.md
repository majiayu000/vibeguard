---
name: vibeguard
description: "AI-assisted development of anti-hallucination specifications. Check out the seven-layer defense architecture, quantitative indicators, execution templates and practical cases. Used for code review, task startup inspection, and weekly review."
---

#VibeGuard — Anti-hallucination specification Skill

## Overview

VibeGuard is an anti-hallucination framework for AI-assisted development that systematically blocks common failure modes in LLM code generation through a seven-layer defense architecture.

Calling `/vibeguard` can:
- View the complete anti-hallucination specifications
- Get task startup checklist
- View the scoring matrix for risk assessment
- Get weekly review template

## Trigger conditions

Triggered when user mentions:
- "Check anti-hallucination specifications", "vibeguard"
- "task startup check", "task contract"
- "Weekly review", "review template"
- "risk assessment", "risk scoring"
- "code quality guard", "guard rules"

## Quick review of seven-layer defense architecture

| Hierarchy | Name | Key Tools/Rules |
|------|------|---------------|
| L1 | Anti-duplicate system | `check_duplicates.py` / Search first then write |
| L2 | Naming constraints | `check_naming_convention.py`/snake_case |
| L3 | Pre-commit Hooks | ruff / gitleaks / shellcheck |
| L4 | Architecture guard testing | `test_code_quality_guards.py` Five rules |
| L5 | Skill/Workflow | plan-flow / fixflow / optflow |
| L6 | Prompt embedded rules | CLAUDE.md mandatory rules |
| L7 | Weekly review | review-template.md |

## Quick use

### Task startup check

```
Refer to references/task-contract.yaml and confirm:
1. Goals are clear and verifiable
2. The data source has been determined
3. Acceptance criteria can be tested
```

### risk assessment

```
Refer to references/scoring-matrix.md to score each finding:
- impact: 1-5
- effort: 1-5
- risk: 1-5
- confidence: 1-5
Formula: priority = (impact × confidence) - (effort + risk)
```

### Weekly review

```
Refer to references/review-template.md, record:
1. Return event this week
2. Guard interception statistics
3. Indicator trends
4. Highlights for next week
```

## Reference documentation

- `references/task-contract.yaml` — Task startup Checklist (machine verification format)
- `references/review-template.md` — weekly review template
- `references/scoring-matrix.md` — risk-impact scoring matrix
- `docs/spec.md` (repository root directory) — complete specification document

## Execution rules

- Go through the task contract before starting each development task
- Conduct a review every Friday, using review template
- When a regression is discovered, first locate the failed defense line and then strengthen the rules.
- New rules must have corresponding automatic detection methods (guard/hook/test)
