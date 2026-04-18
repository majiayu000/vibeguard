---
paths: **/*.py,**/pyproject.toml,**/setup.py
---

# Python Quality Rules

## PY-01: Mutable default parameters (high)
`def f(x=[])` shares state across calls. Fix: use `def f(x=None): if x is None: x = []`.

## PY-02: Bare `except` blocks (medium)
`except:` or `except Exception` without logging or re-raising. Fix: catch a concrete exception type and pair it with logging or a re-raise.

## PY-03: `await` inside loops without `gather()` / `TaskGroup` (medium)
Serial waiting wastes time. Fix: switch to `asyncio.gather()` or `asyncio.TaskGroup` for parallel execution.

## PY-04: God class larger than 500 lines (medium)
More than 10 public methods. Fix: split the class into smaller single-responsibility classes, extract mixins, or create dedicated services.

## PY-05: Repeated try/except patterns across many locations (medium)
Fix: extract a shared error-handler function or decorator.

## PY-06: Rebuilding regexes inside loops (low)
Fix: precompile with `re.compile()` at module load or object initialization time and reuse the compiled pattern in the loop.

## PY-07: String concatenation inside loops (low)
Fix: collect pieces into a list and use `''.join(parts)`.

## PY-08: Use of `eval()`, `exec()`, or `__import__()` (high)
This dynamically executes untrusted code. Fix: replace with a safer alternative. If dynamic execution is unavoidable, strictly constrain the input source and execution environment.

## PY-09: Functions longer than 50 lines (medium)
Fix: extract helper functions so each function stays under 50 lines.

## PY-10: Nesting deeper than 4 levels (medium)
Fix: use guard returns to exit early, or extract the inner block into a dedicated function.

## PY-11: File operations without a `with` context manager (medium)
Fix: convert every open call to `with open(...) as f:`.

## PY-12: Repeated calls to `len()`, `keys()`, or `values()` inside loops (low)
Fix: compute the result once before the loop and reuse the cached value.

## PY-13: Dead compatibility shim (medium)
A file that only re-exports symbols from another module and adds no behavior should be removed after migration is complete.
Fix: update imports to point at the canonical module path, then delete the stale shim once no callers remain.
