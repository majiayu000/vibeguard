---
name: vibeguard
description: "Use VibeGuard anti-hallucination rules, hooks, guards, and verification practices for task startup checks, code review, risk assessment, and weekly review."
---

# VibeGuard

VibeGuard prevents common AI-assisted development failures through compact rules, executable guards, hooks, focused tests, and evidence-based review.

Canonical sources:

- `README.md` — product entry and core/workflow boundary
- `docs/rule-reference.md` — public rule and guard summary
- `schemas/install-modules.json` — install/runtime contract
- `rules/claude-rules/`, `hooks/`, `guards/`, and `vibeguard-runtime/` — implementation

Historical specs and plans are context, not an automatic work queue.

## When to Activate

Use this skill when the user asks for VibeGuard, anti-hallucination checks, task startup constraints, guard rules, risk scoring, code review, or weekly review.

For ordinary implementation work:

- execute clear, bounded tasks directly;
- plan only major architecture or explicitly requested planning;
- keep normal specs to two files and about 300 lines total;
- avoid delegation unless the user asks or ownership is genuinely independent;
- use focused tests during iteration and broader checks before submission.

## Red Flags

- A new rule has no executable guard, hook, test, or evaluation path.
- A clear small task is blocked on a process packet, schema, receipt, or runtime snapshot.
- Multiple writable sessions or agents operate on the same repository.
- A PR continues reviewing after `Findings: 0` and `PASS`, or exceeds two initiated review rounds.
- A completion claim lacks fresh verification from the current session.

## Checklist

- [ ] Confirm goal, context, constraints, and done-when.
- [ ] Search for existing rules, hooks, workflows, skills, and tests.
- [ ] Make the smallest requested change.
- [ ] Run the focused verification command for the changed behavior.
- [ ] Stop review immediately on zero findings and pass.
- [ ] Preserve unrelated worktree changes.

## Seven-Layer Summary

| Layer | Purpose |
|---|---|
| L1 | Search before creating |
| L2 | Naming and boundary conversion |
| L3 | Hooks and fail-visible interception |
| L4 | Architecture and code-quality guards |
| L5 | Small delivery workflows |
| L6 | Compact injected behavior rules |
| L7 | Human review and trend feedback |

## References

- `references/task-contract.yaml` — startup checklist
- `references/review-template.md` — weekly review template
- `references/scoring-matrix.md` — risk/impact scoring
- `workflows/references/delivery-base.md` — delivery and review convergence rules

## Guardrails

- Do not add prose-only enforcement.
- Do not invent APIs, fields, or success evidence.
- Do not swallow user-visible errors.
- Do not turn roadmap or historical documents into work without current user intent.
- Do not build a validator for another spec validator.
