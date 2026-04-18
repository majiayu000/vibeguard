# Python Rules

> Generated from `rules/claude-rules/**` by `python3 scripts/generate_rule_docs.py`. Do not edit by hand.

Reference index for scanning and repairing Python projects.

## Scan checklist

| ID | Rule | Severity | Summary |
| --- | ---- | -------- | ------- |
| PY-01 | Mutable default parameters | High | `def f(x=[])` shares state across calls. |
| PY-02 | Bare `except` blocks | Medium | `except:` or `except Exception` without logging or re-raising. |
| PY-03 | `await` inside loops without `gather()` / `TaskGroup` | Medium | Serial waiting wastes time. |
| PY-04 | God class larger than 500 lines | Medium | More than 10 public methods. |
| PY-05 | Repeated try/except patterns across many locations | Medium | Repeated try/except patterns across many locations |
| PY-06 | Rebuilding regexes inside loops | Low | Rebuilding regexes inside loops |
| PY-07 | String concatenation inside loops | Low | String concatenation inside loops |
| PY-08 | Use of `eval()`, `exec()`, or `__import__()` | High | This dynamically executes untrusted code. |
| PY-09 | Functions longer than 50 lines | Medium | Functions longer than 50 lines |
| PY-10 | Nesting deeper than 4 levels | Medium | Nesting deeper than 4 levels |
| PY-11 | File operations without a `with` context manager | Medium | File operations without a `with` context manager |
| PY-12 | Repeated calls to `len()`, `keys()`, or `values()` inside loops | Low | Repeated calls to `len()`, `keys()`, or `values()` inside loops |
| PY-13 | Dead compatibility shim | Medium | A file that only re-exports symbols from another module and adds no behavior should be removed after migration is complete. |

## Python-adjacent global rules

These are global IDs with Python-specific scope in the canonical rule set:

| ID | Rule | Severity | Summary |
| --- | ---- | -------- | ------- |
| U-30 | Cross-boundary Pydantic models must use `extra="allow"` | Strict | Any Pydantic model that receives external or cross-boundary data must set `extra="allow"` so `model_validate()` does not silently drop un... |
| U-31 | Cache keys must include code version | Strict | When builder or generation logic changes, old cache entries must invalidate automatically. |

## Verification command

```bash
ruff check . && ruff format --check . && pytest
```
