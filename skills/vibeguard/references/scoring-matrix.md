# Risk-Impact scoring matrix

Used to prioritize redundancy/regression findings.

## Rating dimensions

Score each finding from 1 to 5:

### impact
- 1: Ignoreable, pure beautification
- 2: Low impact, only affects readability
- 3: Moderate, significant gains in maintenance/correctness
- 4: High, affecting core functionality or data integrity
- 5: Major, architectural-level improvements or fixes for serious flaws

### effort (workload)
- 1: Very small, partial changes to a single file
- 2: Smaller, 2-3 file changes
- 3: Medium, multiple files and cross-module changes
- 4: Large, needs to be refactored or migrated
- 5: Large, large-scale changes across systems

### risk
- 1: Low, almost impossible to trigger regression
- 2: Lower, the scope of influence is controllable
- 3: Moderate, requires directional test verification
- 4: High, affecting core processes
- 5: High, compatibility sensitive or high regression risk

### confidence
- 1: Weak evidence, just speculation
- 2: Weak, with indirect clues
- 3: Moderate, with partial call path evidence
- 4: Strong, evidence of test/compiler warnings
- 5: Strong evidence, complete call path/test/log

## Priority formula

```
priority_score = (impact × confidence) - (effort + risk)
```

Interpretation:
- The higher the score → the earlier the execution
- Negative score → delayed processing (unless there is a blocking reason that must be processed in advance)

## Stage mapping

| Stage | Condition | Description |
|------|------|------|
| P0 | score >= 12 | Must be prioritized (high impact + high confidence) |
| P1 | 4 <= score < 12 | Obvious value, controllable risk |
| P2 | score < 4 | Cleanup/finishing tasks |

## Score sheet template

```markdown
| id | finding | impact | effort | risk | confidence | score | phase |
|----|---------|--------|--------|------|------------|-------|-------|
| F1 | ...     | 5      | 2      | 2    | 5          | 21    | P0    |
| F2 | ...     | 3      | 3      | 3    | 4          | 6     | P1    |
| F3 | ...     | 2      | 1      | 1    | 3          | 4     | P1    |
| F4 | ...     | 1      | 2      | 2    | 2          | -2    | P2    |
```

## Gating rules

1. Low confidence + high risk changes are not scheduled in P0
2. For high-risk discovery of P0/P1, guard tests must be inserted first and then refactored.
3. Re-evaluate scores for remaining findings after each stage is completed (architectural assumptions may have changed)
4. Discovery without evidence will not be included in the plan
