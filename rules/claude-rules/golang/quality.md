---
paths: **/*.go,**/go.mod,**/go.sum
---

# Go review and tooling

## GO-01: Handle meaningful error returns (high)
Use errcheck, including its -blank option when appropriate, to find discarded error values. Review propagation and handling at the responsible boundary. Arbitrary discarded values are not necessarily errors; direct return of an error is valid and wrapping is useful only when it adds context.

## GO-02: Give goroutines an appropriate lifetime (high)
Check finite work, blocking points, cancellation and which component owns termination. A goroutine that returns does not require a context or select merely to satisfy a rule. Existing project leak tests can provide evidence for executed paths; keywords cannot prove a leak.

## GO-03: Check actual concurrent access (high)
Use the project's applicable go test -race command and review shared access. The race detector covers paths actually executed. Atomic operations, immutable shared data and correct ownership transfer are valid alternatives to a mutex or channel.

## GO-04: Define interfaces at a useful consumer boundary (guideline)
Prefer consumer-defined interfaces when introducing an abstraction that benefits from one. Existing public protocols can define their own interfaces. Do not relocate all interfaces or introduce speculative interfaces solely for mocking.

## GO-08: Check when deferred resources are released (high)
Use Staticcheck SA5003/SA9001 for the loop patterns they cover, then assess actual resource lifetime. Deferred cleanup may intentionally occur when the function returns. Change loops when cleanup timing or resource accumulation is wrong, without mandating helper extraction.

## GO-09: Review functions with mixed responsibilities (guideline)
Split only when independent responsibilities make the requested behavior hard to maintain or test. Length alone, including an 80-line threshold, does not require a refactor.

## GO-10: Review external work during initialization (guideline)
For network or file I/O during init, consider failure reporting, timeouts, test isolation and caller control. Pure initialization and registration can be appropriate; do not prohibit init itself.

## GO-11: Preserve caller cancellation where it applies (high)
Propagate the relevant caller context and deadline through work it owns. A genuinely independent lifetime can have its own root context. Do not rewrite unrelated signatures or reject context.Background solely because a function is not an entrypoint.
