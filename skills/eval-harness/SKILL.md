---
name: eval-harness
description: "Assessment-driven development — Quantify code generation quality with pass@k / pass^k metrics, automatically scored by Grader."
---

# Eval Harness

## Overview

Evaluation-driven development: Not just "can the code run", but quantify "how good is the code".

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
- Security Grader reference `vibeguard/rules/security.md`
- Quality Grader reference `vibeguard/rules/universal.md`
