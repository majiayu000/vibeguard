<!-- vibeguard-start -->
#VibeGuard — AI anti-hallucination rules

> __VIBEGUARD_RULE_COUNT__ rules loaded natively via `~/.claude/rules/vibeguard/`. There is no ORM, no front-end framework, and no microservices in this project.

## Constraints (L1-L7 are enforced by Hooks)

| Layers | Rules |
|----|------|
| L1 | **Must search first** before creating a new one; there is no "Similar files can be created" |
| L2 | snake_case(API boundary camelCase); alias does not exist |
| L3 | Disable silent swallowing of exceptions; there is no public method of Any type |
| L4 | No data = blank; no undeclared API/field exists |
| L5 | Just do what is asked; there is no "easy improvement" |
| L6 | Follow `workflows/references/routing-contract.md`: `execute_direct` / `plan_first` / `clarify_first`, plus the shared handoff fields |
| L7 | AI tag does not exist / force push / key submission |

## Chat Contract

Compact Chat Contract: progress updates, concise answers, plain formatting.

- Progress updates: for non-trivial or tool-heavy work, send a short update at start, after discovery, before edits, after verification, and when blocked.
- Default verbosity: keep answers concise by default; use short paragraphs for simple tasks and expand only when the work is complex or the user asks for depth.
- Formatting: use Markdown only when it helps; prefer prose first, flat bullets only for natural lists, and avoid decorative structure.

## Context · Validation

- Corrected 2 times → `/clear`
- **Must be preserved after Compaction**: (1) List of modified files (2) Constraint set/SPEC (3) Test command (4) Key decisions (5) Current priority (6) L1-L7 rule summary
- **Must be re-read after Compaction**: ongoing preflight constraint set or exec-plan file (if any)
- Before completion: Rust `cargo check` / TS `npx tsc --noEmit` / Go `go build ./...`
- Before submission: Rust `cargo test` / TS project test / Go `go test ./...` / Python `pytest`

## Four elements of the task (ask proactively when there are vague requirements)

| Elements | Questions |
|------|------|
| Goal | What to change/build? |
| Context | Which files/documents/errors are relevant? |
| Constraints | What standards/architectures/conventions must be followed? |
| Done-when | What conditions prove completion? |

## Workflow maturity ladder

**Manual** → After verification → **Skill** → After stable and reliable → **Automation**

- Manual phase: execute directly in the dialog, adjust until reliable
- Skill stage: packaged as SKILL.md, reusable, called by `/skill-name`
- Automation stage: Add scheduled scheduling (launchd/cron) without manual triggering

Rule: Workflows without manual validation are prohibited from direct automation.

## Order

`preflight` prevention · `check` verification · `review` review · `cross-review` confrontation · `build-fix` build · `learn` evolution · `interview` interview · `exec-plan` long cycle · `gc` cleanup · `stats` statistics
(prefix `/vibeguard:`)

## Priority

Security > Logic > Data Splitting > Repeating Types > Unwrap > Naming
<!-- vibeguard-end -->
