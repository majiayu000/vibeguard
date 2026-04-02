# Go Rules (Go specific rules)

Specific rules for scanning and repairing Go projects.

## Scan check items

| ID | Category | Check Item | Severity |
|----|------|--------|--------|
| GO-01 | Bug | Unchecked error return value | High |
| GO-02 | Bug | goroutine leak (no context cancellation or done channel) | High |
| GO-03 | Bug | data race (no mutex or channel for shared variables) | High |
| GO-04 | Design | The interface is defined on the implementation side rather than the consumer side | Medium |
| GO-05 | Dedup | Multiple identical error wrapping patterns | Medium |
| GO-06 | Perf | append within loop not preallocated cap | low |
| GO-07 | Perf | Use + instead of strings.Builder for string concatenation | Low |

## SKIP rules (Go specific)

| Conditions | Judgment | Reasons |
|------|------|------|
| Use init() for initialization | SKIP | Go idiom unless side effects are a concern |
| Exported but unused functions | Check | May be public API, marked DEFER |
| Missing godoc comments | SKIP | Standalone processing |

## ECC enhancement rules

| ID | Category | Check Item | Severity |
|----|------|--------|--------|
| GO-08 | Safety | defer within loop (risk of resource leakage) | High |
| GO-09 | Design | Function exceeds 80 lines (should be split) | Medium |
| GO-10 | Design | Package level init() has side effects (network/file IO) | Medium |
| GO-11 | Safety | context.Background() is used in non-entry functions | Medium |
| GO-12 | Perf | Struct fields not sorted by size (wasted memory alignment) | Low |

## Verification command
```bash
go vet ./... && golangci-lint run && go test ./...
```
