# TypeScript Rules

Reference index for scanning and repairing TypeScript projects.

## Scan checklist

| ID | Category | Check item | Severity |
|----|------|--------|--------|
| TS-01 | Types | `any` escapes in public surfaces | Medium |
| TS-02 | Async | Unhandled Promise rejection | High |
| TS-03 | Correctness | `==` used instead of `===` outside null checks | Medium |
| TS-04 | Design | React component exceeds 300 lines | Medium |
| TS-05 | Dedup | Repeated fetch / API calling patterns | Medium |
| TS-06 | React | `useEffect` missing dependencies or depending too broadly | Medium |
| TS-07 | Perf | Large array mapped during render without memoization | Low |
| TS-08 | Safety | `as any` or `@ts-ignore` bypasses type checking | High |
| TS-09 | Design | Function takes more than 4 parameters | Medium |
| TS-10 | Design | Callback nesting deeper than 3 levels | Medium |
| TS-11 | Safety | Missing null / undefined handling | Medium |
| TS-12 | Perf | Passing whole objects as props when only fields are needed | Low |
| TS-13 | Dedup | Equivalent components or hooks exist under different names | High |
| TS-14 | Testing | Mock shape drifts from the real module export shape | High |

## Verification command

```bash
npx tsc --noEmit && npx eslint . && npm test
```
