# Go Rules

> Generated from `rules/claude-rules/**` by `python3 scripts/generate_rule_docs.py`. Do not edit by hand.

Reference index for scanning and repairing Go projects.

## Scan checklist

| ID | Rule | Severity | Summary |
| --- | ---- | -------- | ------- |
| GO-01 | Unchecked error return values | High | Errors are assigned to `_` and discarded. |
| GO-02 | Goroutine leak | High | `go func()` launches work without an exit path. |
| GO-03 | Data race | High | Shared variables are accessed without a mutex or channel protection. |
| GO-04 | Interface is declared on the implementation side instead of the consumer side | Medium | Interface is declared on the implementation side instead of the consumer side |
| GO-05 | Repeated error-wrapping patterns across multiple places | Medium | Repeated error-wrapping patterns across multiple places |
| GO-06 | `append` in loops without preallocated capacity | Low | `append` in loops without preallocated capacity |
| GO-07 | String concatenation with `+` instead of `strings.Builder` | Low | String concatenation with `+` instead of `strings.Builder` |
| GO-08 | `defer` inside loops | High | This risks resource leaks because deferred calls wait until the function returns. |
| GO-09 | Functions longer than 80 lines | Medium | Functions longer than 80 lines |
| GO-10 | Package-level `init()` has side effects | Medium | Network or file I/O happens in `init()`. |
| GO-11 | `context.Background()` is used outside entry points | Medium | `context.Background()` is used outside entry points |
| GO-12 | Struct fields are not ordered by size | Low | This wastes memory due to alignment padding. |

## Verification command

```bash
go vet ./... && golangci-lint run && go test ./...
```
