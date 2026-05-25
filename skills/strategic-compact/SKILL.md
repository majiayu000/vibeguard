---
name: strategic-compact
description: "Strategic compression — Manual compression of contexts at logical boundaries rather than arbitrary automatic compression. Key decisions and constraints are preserved and intermediate exploration is discarded."
---

# Strategic Compact

## Overview

In long sessions, the context window is limited. This skill guides when to compact, what to keep, and what to discard.

Core principle: **Compress at logical boundaries, not at any time. **

## When to Activate

- A long-running task is approaching context limits and needs a compact handoff.
- Work is crossing a phase boundary such as discovery to implementation or implementation to verification.
- A session must preserve decisions, modified files, constraints, tests, and unfinished steps.
- The user asks to compress, checkpoint, or make the current state resumable.
- A session is about to cross a planning, implementation, validation, or handoff boundary.
- The context window is close to compaction and important decisions must survive.
- The user asks to save or preserve state before continuing later.

## Red Flags

- Compression happens midway through an implementation step with unstated file changes.
- The retained summary omits constraints, modified files, validation commands, or current priority.
- Exploration transcripts are preserved while actual decisions and blockers are lost.

## Checklist

- [ ] Record the current mission, constraints, modified files, and next step.
- [ ] Preserve verification commands and whether they passed or failed.
- [ ] Drop redundant search output after retaining the evidence-backed conclusions.

## Compress decision table

| Current stage | Next stage | Whether to compress | Reason |
|----------|----------|----------|------|
| Research/Exploration | Planning | Yes | Exploration details do not need to be brought into planning |
| Plan | Implement | Yes | Keep the plan, discard the planning process |
| Implementation step N | Implementation step N+1 | No | Compression during implementation will lose context |
| Implementation complete | Validation | Optional | If the context is close to the upper limit |
| Verify | Submit | No | Verification results need to be submitted |
| Task A completed | Task B started | Yes | Compression between different tasks |

## Keep list after compression

Must be retained:
- Current mission goals and constraints
- Architectural decisions made and reasons
- list of modified files
- Unfinished steps
- Issues found and TODO
- VibeGuard constraints (always retained)

Can be discarded:
- A complete reference to the file content (just keep the path)
- Intermediate results during search
- Full stack of resolved bugs
- Exploratory code reading record

## Usage

When it feels like the context is running out:

1. Determine which stage you are currently in
2. Check the compression decision table to confirm whether compression is suitable
3. If appropriate, organize summaries by retention list
4. Perform compression

## Red Flags

- **Compacting mid-implementation** - losing the current edit path can cause duplicated or contradictory work.
- **Dropping constraints** - the next session may violate VibeGuard rules without realizing the guardrail existed.
- **No modified-file list** - resume work becomes guesswork.
- **Waiting for overflow** - passive truncation is less reliable than deliberate compression.

## Checklist

- [ ] Preserve current goal, constraints, and done-when criteria.
- [ ] List modified files and pending verification commands.
- [ ] Record key decisions and why they were made.
- [ ] Keep unresolved blockers and next priority explicit.
- [ ] Remove bulky intermediate search details once the conclusion is captured.
