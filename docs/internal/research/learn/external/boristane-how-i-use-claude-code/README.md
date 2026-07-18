# How I Use Claude Code

- Source URL: https://boristane.com/blog/how-i-use-claude-code/
- Source author: Boris Tane
- Source published: 2026-02-10
- Captured from mirror metadata: 2026-03-05 19:10:55 CST
- Reviewed for VibeGuard: 2026-06-20

Internal research context only; this note summarizes the source and is not a
VibeGuard product contract.

## Summary

The article describes a disciplined Claude Code workflow: deep repository
research first, a persistent Markdown plan second, user annotation cycles before
implementation, then a bounded execution pass against the reviewed plan. The
main claim is that AI coding works better when research, planning, human
judgment, and execution are separated into explicit artifacts instead of handled
as one continuous prompt.

## VibeGuard-specific implications

- Reinforces VibeGuard's search-first and no-fix-without-root-cause rules:
  substantive implementation should start from codebase research, not guessed
  architecture.
- Supports making `research.md` and `plan.md` first-class handoff artifacts for
  larger work, especially when compaction or worker handoff is likely.
- Treats human annotations as constraints that must be folded back into the plan
  before execution, matching VibeGuard's preference for explicit scope and
  stop-conditions.
- Keeps implementation workers mechanical: once a plan is accepted, the worker
  should execute the agreed checklist and verify continuously rather than invent
  extra improvements.
