# Python Rules (Python specific rules)

Specific rules for scanning and repairing Python projects.

## Scan check items

| ID | Category | Check Item | Severity | Guard Cross Reference |
|----|------|--------|--------|-------------|
| PY-01 | Bug | Variable default parameters (def f(x=[])) | High | — |
| PY-02 | Bug | except naked catch (except: or except Exception) | Medium | `guards/python/test_code_quality_guards.py` Rule 1 Autodetection |
| PY-03 | Bug | await within loop without gather/TaskGroup | Medium | — |
| PY-04 | Design | God class (>500 lines, >10 public methods) | Medium | — |
| PY-05 | Dedup | The same try/except pattern in many places | Medium | — |
| PY-06 | Perf | Repeated creation of regular expressions within loops (should be precompiled) | Low | — |
| PY-07 | Perf | String concatenation in a loop (applying join or list) | Low | — |

> **PY-02 and Guard Integration Instructions**: The "disable silent exception swallowing" rule in VibeGuard's `guards/python/test_code_quality_guards.py` detects whether the except block has logging or re-raise through AST. When auto-optimize scans, you should run this guard first to obtain the baseline, and LLM deep scan to supplement the scenarios that the guard cannot cover (for example, the except block has logging but the exception type is too wide).

## SKIP rules (Python specific)

| Conditions | Judgment | Reasons |
|------|------|------|
| Type annotations are incomplete but functionally correct | SKIP | Type annotations are progressive |
| Use dict instead of dataclass | SKIP | Unless dict structure is repeated at > 3 places |
| Missing docstring | SKIP | Independent processing, no mixing function fixes |

## ECC enhancement rules

| ID | Category | Check Item | Severity |
|----|------|--------|--------|
| PY-08 | Safety | Using `eval()` / `exec()` / `__import__()` | High |
| PY-09 | Design | Function exceeds 50 lines (should be split) | Medium |
| PY-10 | Design | Nesting beyond 4 levels (functions should be returned or extracted early) | Medium |
| PY-11 | Safety | File operations not using `with` context manager | Medium |
| PY-12 | Perf | Repeated calls to `len()` / `keys()` / `values()` in a loop | Low |

## Verification command
```bash
ruff check . && ruff format --check . && pytest
```
