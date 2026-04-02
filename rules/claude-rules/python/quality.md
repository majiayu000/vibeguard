---
paths: **/*.py,**/pyproject.toml,**/setup.py
---

# Python quality rules

## PY-01: Variable default parameters (high)
`def f(x=[])` results in shared state across calls. Fix: `def f(x=None): if x is None: x = []`

## PY-02: except naked capture (medium)
No logging/re-raise for `except:` or `except Exception`. Fix: Capture specific exception types and cooperate with logging or re-raise.

## PY-03: await within the loop without gather/TaskGroup (medium)
Serial waiting wastes time. Fix: Change to `asyncio.gather()` or `asyncio.TaskGroup` for concurrent execution.

## PY-04: God class > 500 lines (medium)
More than 10 public methods. Fix: Split into multiple classes with single responsibilities, extract mixins or independent services.

## PY-05: The same try/except pattern in many places (medium)
Fix: Extract public error handler function or decorator.

## PY-06: Repeated creation of regular expressions within a loop (low)
Fix: Use `re.compile()` to precompile during module level or class initialization and reuse within loops.

## PY-07: String concatenation in loops (low)
Fix: Use `''.join(parts)` after list collection instead.

## PY-08: Use eval() / exec() / __import__() (high)
Dynamically execute untrusted code. Fix: Replaced with safe alternative. Must be used with strict restrictions on input sources and execution environments.

## PY-09: Function exceeds 50 lines (medium)
Fix: Extract sub-functions, and a single function should not exceed 50 lines.

## PY-10: Nesting beyond 4 levels (medium)
Fix: Use guard return to exit early, or extract the inner layer into an independent function.

## PY-11: File operations not using with context manager (medium)
Fix: All files open use `with open(...) as f:` instead.

## PY-12: Repeated calls to len()/keys()/values() within a loop (low)
Fix: cache the results to variables before looping and reuse them within the loop.
