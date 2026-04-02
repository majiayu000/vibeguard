---
name: strategic-compact
description: "Strategic compression — Manual compression of contexts at logical boundaries rather than arbitrary automatic compression. Key decisions and constraints are preserved and intermediate exploration is discarded."
---

# Strategic Compact

## Overview

In long sessions, the context window is limited. This skill guides when to compact, what to keep, and what to discard.

Core principle: **Compress at logical boundaries, not at any time. **

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

## Anti-pattern

- Minification mid-implementation → Loss of critical context, resulting in duplication of work
- Constraints discarded during compression → subsequent steps violate rules
- No compression until overflow → Passive truncation is more dangerous than active compression
