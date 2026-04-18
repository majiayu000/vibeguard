# Python Rules

Reference index for scanning and repairing Python projects.

## Core Python checks

| ID | Category | Check item | Severity |
|----|------|--------|--------|
| PY-01 | Bug | Mutable default parameters (`def f(x=[])`) | High |
| PY-02 | Bug | Bare `except:` or overly broad `except Exception` without logging / re-raise | Medium |
| PY-03 | Async | `await` inside loops without `gather()` / `TaskGroup` | Medium |
| PY-04 | Design | God class (>500 lines or >10 public methods) | Medium |
| PY-05 | Dedup | Repeated try/except patterns in multiple places | Medium |
| PY-06 | Perf | Regex creation repeated inside loops | Low |
| PY-07 | Perf | String concatenation inside loops | Low |
| PY-08 | Safety | Use of `eval()`, `exec()`, or `__import__()` | High |
| PY-09 | Design | Function exceeds 50 lines | Medium |
| PY-10 | Design | Nesting deeper than 4 levels | Medium |
| PY-11 | Safety | File operations without `with` context managers | Medium |
| PY-12 | Perf | Repeated `len()` / `keys()` / `values()` inside loops | Low |
| PY-13 | Cleanup | Dead compatibility shim that only re-exports another module | Medium |

## Python-adjacent global rules

These live in the canonical Python rule surface even though they use `U-` IDs:

| ID | Summary |
|----|---------|
| U-30 | Cross-boundary Pydantic models must use `extra="allow"` when they validate external data |
| U-31 | Cache keys must include a code version so builder changes invalidate stale output |

## Verification command

```bash
ruff check . && ruff format --check . && pytest
```
