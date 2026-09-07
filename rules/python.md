# Python Rules

> Generated from `rules/claude-rules/**` by `python3 scripts/generate_rule_docs.py`. Do not edit by hand.

Reference index for scanning and repairing Python projects.

## Linter Boundary

These rules do not replace native linters. Treat lint-equivalent entries as agent reminders and review triage; use the verification command below for mechanical enforcement. Semantic/contextual entries remain useful when native linters lack project-level context.

## Scan checklist

| ID | Rule | Severity | Summary |
| --- | ---- | -------- | ------- |
| PY-01 | Mutable default parameters | High | `def f(x=[])` shares state across calls. |
| PY-02 | Bare `except` blocks | Medium | `except:` or `except Exception` without logging or re-raising. |
| PY-03 | Consider concurrency for independent async work | Guideline | Parallelize independent operations when it improves the current task and respects rate limits, ordering, and resource ownership. |
| PY-04 | God class larger than 500 lines | Medium | More than 10 public methods. |
| PY-05 | Repeated try/except patterns across many locations | Medium | Repeated try/except patterns across many locations |
| PY-06 | Rebuilding regexes inside loops | Low | Rebuilding regexes inside loops |
| PY-07 | String concatenation inside loops | Low | String concatenation inside loops |
| PY-08 | Use of `eval()`, `exec()`, or `__import__()` | High | This dynamically executes untrusted code. |
| PY-09 | Review functions with mixed responsibilities | Guideline | Length is a review signal, not a reason to extract helpers by itself. |
| PY-10 | Nesting deeper than 4 levels | Medium | Nesting deeper than 4 levels |
| PY-11 | File operations without a `with` context manager | Medium | File operations without a `with` context manager |
| PY-13 | Dead compatibility shim | Medium | A file that only re-exports symbols from another module and adds no behavior should be removed after migration is complete. |

## Python-adjacent global rules

These are global IDs with Python-specific scope in the canonical rule set:

| ID | Rule | Severity | Summary |
| --- | ---- | -------- | ------- |
| U-30 | Make unknown-field handling explicit at data boundaries | Strict | Choose unknown-field handling from the data contract, and prevent accidental loss of fields the consumer needs. |
| U-31 | Invalidate caches when result semantics change | Strict | When a change alters a cached result's meaning or representation, ensure stale entries cannot be reused as current output. |

## Verification command

```bash
ruff check . && ruff format --check . && pytest
```
