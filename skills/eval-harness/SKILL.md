---
name: eval-harness
description: "Assessment-driven development — Quantify code generation quality with pass@k / pass^k metrics, automatically scored by Grader."
---

# Eval Harness

## Overview

Evaluation-driven development: Not just "can the code run", but quantify "how good is the code".

## When to Activate

- Designing or changing an evaluation harness for agent behavior or guard quality.
- Comparing prompt, skill, hook, or workflow variants with measurable outcomes.
- Adding a regression gate that must prove repair without hiding unrelated-task regressions.
- Converting subjective review criteria into deterministic or model-graded metrics.
- A guard, hook, workflow, or skill needs measurable repair/regression evidence before adoption.
- A user asks whether an agent workflow is actually improving quality rather than only passing one example.
- A change affects scoring, grading, or benchmark thresholds.

## Red Flags

- Only one hand-picked success case exists and there is no held-out or unrelated task coverage.
- A probabilistic grader is used where a deterministic build, test, lint, or coverage check is available.
- pass@k improves while pass^k or unrelated-task behavior regresses.

## Checklist

- [ ] Define deterministic checks before adding model-judged grading.
- [ ] Record target and unrelated scenarios with before/after outcomes.
- [ ] Report pass@k, pass^k, and regression counts separately.

## Core indicators

### pass@k (single success rate)

- Generate k candidate solutions, with a probability of at least 1 passing
- Used to evaluate the completion quality of a single task
- Target: pass@1 > 80%

### pass^k (continuous success rate)

- The probability of passing all k consecutive tasks at once
- Used to evaluate overall workflow reliability
- Goal: pass^5 > 50% (pass all 5 consecutive tasks in one go)

## Grader type

### Code Basics Grader (deterministic)

| Grader | Check content | Pass conditions |
|--------|----------|----------|
| Compilation check | Whether the code can be compiled / type check passed | Zero errors |
| Test check | Whether all tests passed | Full green |
| Lint check | Whether the code style conforms to the specification | Zero warnings (or only allowed warnings) |
| Coverage check | Check whether the test coverage reaches the standard | ≥ 80% |

### Model base Grader (probabilistic)

| Grader | Check content | How to grade |
|--------|----------|----------|
| Code review | Code quality, readability, security | 0-10 points |
| Requirements matching | Whether the implementation meets the requirements | 0-1 matching degree |
| Architecture evaluation | Is the design reasonable | 0-10 points |

## Usage process

1. **Define Evaluation Criteria**
   - Extract verifiable passing conditions from requirements
   - Choose the right grader combination

2. **Run the evaluation**
   - Code base Grader first (fast, deterministic)
   - Model basics Grader supplement (depth, probabilistic)

3. **Analysis results**
   - pass@1 < 80% → Unclear requirements or problematic implementation strategies
   - pass^5 < 50% → There is a systemic problem with the workflow

4. **Improvements**
   - Adjust strategies based on failure patterns
   - Updated Grader rules

## VibeGuard Integration

- Code base Grader can reuse guard script output (such as `guards/<lang>/check_*.sh`)
- Security Grader reference `rules/claude-rules/common/security.md`
- Quality Grader reference `rules/claude-rules/common/coding-style.md`

## Red Flags

- **No baseline** - a score without previous behavior cannot prove improvement.
- **Only happy-path samples** - evals that skip failure cases will bless fragile workflows.
- **Mixed deterministic and model scores** - combining them without labels hides which result is reproducible.
- **No held-out set** - tuning directly on the decision set overfits the workflow.

## Checklist

- [ ] Define the target behavior, baseline, and pass threshold before running the eval.
- [ ] Include target repairs and unrelated regression cases.
- [ ] Label each grader as deterministic or probabilistic.
- [ ] Persist the artifact path or command output used for the verdict.
- [ ] Re-run the focused eval after any harness or scoring change.
