---
paths: **/evals/**,**/eval/**,**/evaluations/**,**/benchmarks/**,**/tests/eval*/**,**/*eval*.py,**/*eval*.ts,**/*eval*.tsx,**/*eval*.js,**/*eval*.rs,**/*eval*.go,**/pyproject.toml,**/package.json,**/Cargo.toml,**/go.mod
---

# Evaluation Validation Rules

## Applicability

W-18 applies when developing or reviewing eval harnesses, benchmark suites, agent-evaluation pipelines, or release gates that rely on model/agent evaluation results. For tasks that do not touch eval definitions, eval runners, benchmark fixtures, or eval-related dependencies, this rule is not part of the active task contract.

## W-18: Evaluations must validate path, not only output (strict)
Output-only evaluations miss systemic failures. An agent or pipeline can produce the correct final answer through the wrong tool, by skipping a required step, or with miscalibrated confidence; in production these all read as "passing" but degrade the moment the inputs shift.

**Sources** (2026-04-27):
- Confident AI, "Three Ways AI Systems Fail Even When Evals Pass" - names the three failure modes below
- Microsoft Research, AgentRx (2026-04) - the same failure modes recur in the 9-class trajectory taxonomy
- Anthropic Claude Code postmortem (2026-04-24) - quality degradation that no end-to-end eval caught, because the eval did not look at session-state behavior

**The three failure modes that pass output-only evals**:

| Mode | Description | What the eval saw | What was actually wrong |
|------|-------------|-------------------|-------------------------|
| Wrong tool, right answer | Used a search tool when a structured DB lookup was required | Correct value in response | Cached or pretrained knowledge, not the current source of truth |
| Skipped required step | Answered without doing the mandatory retrieval / validation step | Correct answer | Bypassed the very check that the system was designed to enforce |
| Miscalibrated confidence | Returned a wrong answer with high stated certainty | "Confident" output | No signal for downstream caller to fall back |

**Required eval coverage (strict)**:

Every eval suite that gates a release or guards a production agent must validate three axes, not one:

1. **Tool selection** - assert that the trajectory used the expected tool (or a member of an allowed set) for each protected step. If the agent has no tools, this axis is vacuous and may be skipped, but the suite must say so explicitly.
2. **Step adherence** - assert that the trajectory contains every mandatory step in the documented order. Examples: retrieval before answer, schema validation before write, permission check before mutation. A "skip step" must fail the eval even when the final output is correct.
3. **Confidence calibration** - assert that stated confidence tracks correctness on the eval set. Concretely, expected calibration error (ECE) on the bucketed predictions must be reported alongside accuracy. An agent that is 90% confident on a sample where it is correct 50% of the time is a calibration failure even if accuracy is "fine".

**Mechanical checks (agent execution rules)**:
- When asked to "evaluate" a model, agent, or pipeline, first ask: does the suite log the trajectory (tool calls, ordered steps, stated confidence) or only the final output?
- If only the final output is logged, the suite cannot satisfy W-18. The required fix is to record trajectory metadata, not to add more output-level cases.
- When adding a new eval case, declare its target axis. A case that does not exercise tool selection, step adherence, or confidence calibration is an output-only case and must be balanced by cases on the other axes.
- Reject pull requests that claim "evals pass" while the eval definition does not assert any of the three axes.

**Anti-patterns**:
- Reporting `pass@k` as the only quality metric for a tool-using agent.
- Adding more end-to-end golden outputs to "harden" a regression that was actually a tool-selection or step-skip failure.
- Reading model confidence directly without ever measuring how it correlates with correctness.
- Marking a release green because output-level evals are stable, when the underlying trajectory shape has changed.

**Downgrade path**:
For pure text generation tasks with no tools and no required intermediate steps, axes 1 and 2 are vacuous and may be skipped if the eval suite explicitly states so. Axis 3 (calibration) is never optional whenever the model emits or implies a confidence value to a caller.
