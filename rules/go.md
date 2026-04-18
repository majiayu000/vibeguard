# Go Rules

Reference index for scanning and repairing Go projects.

## Scan checklist

| ID | Category | Check item | Severity |
|----|------|--------|--------|
| GO-01 | Bug | Unchecked error return value | High |
| GO-02 | Concurrency | Goroutine leak (no cancellation path) | High |
| GO-03 | Concurrency | Data race on shared state | High |
| GO-04 | Design | Interface declared on implementation side instead of consumer side | Medium |
| GO-05 | Dedup | Repeated error-wrapping patterns | Medium |
| GO-06 | Perf | `append` inside loops without preallocated capacity | Low |
| GO-07 | Perf | String concatenation with `+` instead of `strings.Builder` | Low |
| GO-08 | Safety | `defer` inside loops | High |
| GO-09 | Design | Function exceeds 80 lines | Medium |
| GO-10 | Design | Package-level `init()` has network or file side effects | Medium |
| GO-11 | Safety | `context.Background()` is used outside entry points | Medium |
| GO-12 | Perf | Struct fields not arranged to reduce padding | Low |

## Verification command

```bash
go vet ./... && golangci-lint run && go test ./...
```
