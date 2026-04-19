# TypeScript Rules

> Generated from `rules/claude-rules/**` by `python3 scripts/generate_rule_docs.py`. Do not edit by hand.

Reference index for scanning and repairing TypeScript projects.

## Scan checklist

| ID | Rule | Severity | Summary |
| --- | ---- | -------- | ------- |
| TS-01 | `any` type escape | Medium | Function parameters or return values use `any`. |
| TS-02 | Unhandled Promise rejections | High | Async calls lack error handling. |
| TS-03 | `==` instead of `===` | Medium | Loose equality is used outside explicit null checks. |
| TS-04 | Oversized component larger than 300 lines | Medium | React component is too large. |
| TS-05 | Repeated fetch / API call patterns across the codebase | Medium | Repeated fetch / API call patterns across the codebase |
| TS-06 | `useEffect` has missing or overly broad dependencies | Medium | `useEffect` has missing or overly broad dependencies |
| TS-07 | Large arrays are mapped during render without memoization | Low | Large arrays are mapped during render without memoization |
| TS-08 | Bypassing type checks with `as any` or `@ts-ignore` | High | Bypassing type checks with `as any` or `@ts-ignore` |
| TS-09 | Functions with more than 4 parameters | Medium | Functions with more than 4 parameters |
| TS-10 | Callback nesting deeper than 3 levels | Medium | Callback nesting deeper than 3 levels |
| TS-11 | Unhandled `null` / `undefined` | Medium | Missing optional chaining or null guards. |
| TS-12 | Passing full objects as component props instead of only required fields | Low | Passing full objects as component props instead of only required fields |
| TS-13 | Duplicate component or hook behavior under different names | High | Multiple files define React components or hooks with equivalent behavior but different names. |
| TS-14 | Test mocks drift from the real module shape | High | `vi.mock()` and `jest.mock()` factory functions often return `any`, so TypeScript cannot tell when the mock shape drifts from the real mo... |

## Verification command

```bash
npx tsc --noEmit && npx eslint . && npm test
```
