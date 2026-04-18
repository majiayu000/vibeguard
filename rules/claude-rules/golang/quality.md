---
paths: **/*.go,**/go.mod,**/go.sum
---

# Go Quality Rules

## GO-01: Unchecked error return values (high)
Errors are assigned to `_` and discarded. Fix: use `if err != nil { return fmt.Errorf("context: %w", err) }`.

## GO-02: Goroutine leak (high)
`go func()` launches work without an exit path. Fix: pass `context.Context` and exit via `select { case <-ctx.Done(): return }`.

## GO-03: Data race (high)
Shared variables are accessed without a mutex or channel protection. Fix: guard them with `sync.Mutex` / `sync.RWMutex`, or communicate through channels.

## GO-04: Interface is declared on the implementation side instead of the consumer side (medium)
Fix: move the interface into the consuming package and depend on abstractions from the consumer side.

## GO-05: Repeated error-wrapping patterns across multiple places (medium)
Fix: standardize on `fmt.Errorf("...: %w", err)`.

## GO-06: `append` in loops without preallocated capacity (low)
Fix: preallocate with `make([]T, 0, expectedLen)`.

## GO-07: String concatenation with `+` instead of `strings.Builder` (low)
Fix: use `strings.Builder` or `strings.Join`.

## GO-08: `defer` inside loops (high)
This risks resource leaks because deferred calls wait until the function returns. Fix: extract the loop body into a helper so each `defer` runs at the right scope.

## GO-09: Functions longer than 80 lines (medium)
Fix: extract helper functions so each function stays under 80 lines.

## GO-10: Package-level `init()` has side effects (medium)
Network or file I/O happens in `init()`. Fix: move it into an explicit initialization function controlled by the caller.

## GO-11: `context.Background()` is used outside entry points (medium)
Fix: thread a `context.Context` through the call chain as the first argument. Non-entry functions should not create root contexts.

## GO-12: Struct fields are not ordered by size (low)
This wastes memory due to alignment padding. Fix: sort fields in descending size order when it is reasonable to do so.
