---
name: trajectory-review
description: "Post-hoc diagnosis of a failed agent trajectory. Classifies the first unrecoverable step into one of nine failure categories (plan adherence, hallucinated information, invalid tool call, misread tool output, intent–plan mismatch, under-specified intent, unsupported intent, guardrail trigger, system failure) and produces an evidence-backed root-cause report."
---

# Trajectory Review

## Overview

When an agent run fails, the failure mode is rarely "the model is bad". It is usually one of a small set of recurring problems on the trajectory: the agent skipped a planned step, invented a fact, called a tool wrong, misread a tool's output, or pursued the wrong subgoal entirely. Output-only review cannot distinguish these — they all surface as "the answer was wrong".

This skill takes a captured trajectory (tool calls, intermediate outputs, final response) and locates the **first unrecoverable step**, classifies it into one of nine categories, and reports the root cause with citations into the trajectory.

The taxonomy and four-stage diagnostic procedure are adapted from Microsoft Research's AgentRx framework (2026-04). The classes themselves are stable across agent stacks; the diagnostic stages are how this skill operates inside a Claude Code or Codex session.

## When to use

- An agent run produced a wrong or incomplete result and you have the trajectory.
- A user reports "the agent is broken" and a postmortem is needed.
- A regression appeared after a model upgrade and you need to know whether it is a model issue or a harness issue.
- A new capability shipped and you want to characterize the failure modes that remain.
- A user says "review the trajectory", "diagnose this run", or "why did the agent fail".

Do **not** use this skill to evaluate a passing run. For "evals pass but I don't trust it", use the W-18 three-axis evaluation framing instead.

## The nine failure categories

| ID | Category | Recognition signal |
|----|----------|--------------------|
| F1 | **Plan adherence failure** | A required step in the stated plan is missing from the trajectory, or an unplanned step appears |
| F2 | **Hallucinated information** | The trajectory cites a fact, file, function, or value that the tool outputs and prior context never produced |
| F3 | **Invalid tool invocation** | A tool call has malformed arguments, wrong types, missing required fields, or an unsupported method |
| F4 | **Misread tool output** | The tool returned correctly, but the agent's next step uses a value that is not in the output, or interprets a list as a single item |
| F5 | **Intent–plan mismatch** | The plan addresses a different goal than the user's request — e.g. user asks to debug, agent plans to refactor |
| F6 | **Under-specified intent** | The user's request lacks information the agent needs; the agent guesses rather than asking |
| F7 | **Unsupported intent** | No available tool can do what the user wants and the agent does not say so |
| F8 | **Guardrail triggered** | A safety, permissions, or rate-limit guardrail blocked the action and the agent did not surface that |
| F9 | **System failure** | An external endpoint, network call, or runtime crashed and the agent treated the empty response as a valid one |

The same trajectory can show multiple categories. The skill reports them all but identifies which one is the **first unrecoverable** step — the point past which the run could not have produced the right answer regardless of what came after.

## Four-stage diagnostic procedure

### Stage 1 — Trajectory normalization

Convert whatever was captured (chat transcript, tool-call log, JSONL events, screen recording transcript) into a uniform sequence of `(step_index, role, action, payload, observed_output)` records. If a stage is missing (for example, the user only provided the final answer), say so and stop. Do not invent the missing trajectory.

### Stage 2 — Constraint synthesis

For each tool used in the trajectory, restate the contract the tool enforced or should have enforced: required arguments, allowed values, declared post-conditions. Source these from the tool's schema if available, otherwise from the project's `AGENTS.md` / `CLAUDE.md` declarations.

For the user's request, restate the goal as a checklist of intermediate states the trajectory must reach.

This stage is where most diagnoses become possible — once the contracts are explicit, F3, F4, F8, and F9 become mechanical to detect.

### Stage 3 — Guarded evaluation (per step)

Walk the trajectory step by step. For each step, evaluate it against:

- the prior step's observed output (does this step depend on a value that was actually produced?)
- the tool contract (does this call respect the schema?)
- the plan declared earlier in the trajectory (does this step appear in the plan, or is it unplanned?)
- the user's goal checklist (does this step advance any required intermediate state?)

Mark each step as `ok | warn | fail`, with the specific check that failed. Do not jump ahead; the first `fail` is the first unrecoverable step.

### Stage 4 — Classification and root-cause attribution

For the first `fail` step, assign an F-class. Cite:
- the step index
- the failed check from stage 3
- the contract or plan element that was violated
- one or two earlier steps that contributed (for example, an F4 misread is often caused by a prior over-summarization)

If the first `fail` is genuinely a system-level fault (F9), say so without escalating to a deeper class. The bias here matters: classifying everything as "model hallucination" hides harness bugs.

## Output format

```
# Trajectory review — <run id or label>

## Trajectory
- captured stages: <plan | tool calls | outputs | final answer> — <complete | partial>
- step count: N

## Tool contracts (synthesized)
- <tool name>: <args>, <constraints>, <post-conditions>
- ...

## Goal checklist
1. <required intermediate state>
2. ...

## Step-by-step evaluation
| step | action | check | result |
|------|--------|-------|--------|
| 1 | ... | ... | ok |
| 2 | ... | ... | warn |
| 3 | ... | ... | fail (first unrecoverable) |

## Root cause
- Class: <F1–F9>
- First unrecoverable step: <index>
- Failed check: <name>
- Contributing prior steps: <indices>
- Evidence: <verbatim citation from the trajectory>

## Recommendations
- <smallest harness or prompt change that prevents this class on this trajectory>
- <rule, guard, or eval case that would have caught it>
```

## Boundaries

- This skill diagnoses **one** trajectory at a time. For aggregate analysis across many runs, use a separate batch tool. Do not generalize a single trajectory's class to a system-wide claim.
- It does **not** rerun the trajectory. The diagnosis is on what was captured.
- It does **not** rewrite the agent's prompt or skills. Recommendations are descriptive; implementation is a separate explicit ask.
- For a passing trajectory whose path concerns you anyway, switch to W-18 three-axis evaluation rather than running this skill.

## Anti-patterns inside this skill

- Marking the **last** failed step instead of the first unrecoverable one. The last step is usually a downstream consequence.
- Defaulting to F2 (hallucination) without checking F4 (misread). They look identical in the final answer but require opposite fixes.
- Classifying an F9 system failure as F1 plan adherence because the agent retried oddly after the timeout. The retry behavior is a symptom, not the cause.
- Producing a class with no citation. Every F-class assignment must point to a specific step and contract.
- Building a multi-step reasoning chain on top of a step that was already marked `fail`. The classification stops at the first unrecoverable step.

## Related rules

- `W-01` — no fixes without root cause. The first unrecoverable step is the root cause; downstream symptoms are not.
- `W-15` — low-information loop detection. If the trajectory shows three rounds of shrinking diff with no progress, the F-class is more likely F1 or F5 than F2.
- `W-18` — evaluations must validate path. The nine-class taxonomy is what an axis-1 (tool selection) and axis-2 (step adherence) eval would assert against.
- `SEC-12` — silent drift in MCP tool descriptions. If F4 (misread tool output) recurs across trajectories, audit the MCP tool descriptions before blaming the model.
