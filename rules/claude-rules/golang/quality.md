---
paths: **/*.go,**/go.mod,**/go.sum
---

#Go Quality Rules

## GO-01: Unchecked error return value (high)
Assignment to `_` discards errors. Fix: `if err != nil { return fmt.Errorf("context: %w", err) }`

## GO-02: goroutine leak (high)
`go func()` has no exit mechanism. Fix: Pass in `context.Context`, use `select { case <-ctx.Done(): return }`

## GO-03: data race (high)
Shared variables have no mutex or channel protection. Fix: Use `sync.Mutex`/`sync.RWMutex` protection, or use channel communication instead.

## GO-04: The interface is defined on the implementation side rather than the consumer side (middle)
Repair: The interface is moved to the consumer package to be defined, following the principle of "depending on the interface and not on the implementation".

## GO-05: Multiple identical error wrapping patterns (medium)
Fix: Uniformly use `fmt.Errorf("...: %w", err)` format.

## GO-06: append within loop not preallocated cap (low)
Fix: `make([]T, 0, expectedLen)` preallocates slice capacity.

## GO-07: Use + instead of strings.Builder for string concatenation (low)
Fix: Use `strings.Builder` or `strings.Join` instead.

## GO-08: defer inside loop (high)
Risk of resource leakage, defer is not executed until the end of the function. Fix: Extract the loop body into a standalone function and defer is executed inside the function.

## GO-09: Function exceeds 80 lines (medium)
Fix: Extract sub-functions so that a single function does not exceed 80 lines.

## GO-10: Package-level init() has side effects (medium)
Network/file IO is performed in init(). Fix: Moved to explicit initialization function, caller controls timing.

## GO-11: context.Background() used in non-entry functions (medium)
Fix: Pass context as first parameter from the top of the call chain. Non-entry functions do not create a root context.

## GO-12: Struct fields not sorted by size (low)
Memory alignment is a waste. Fix: Sort by field size in descending order (big fields first), reduce padding.
