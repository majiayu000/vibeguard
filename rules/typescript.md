# TypeScript Rules (TypeScript specific rules)

Specific rules for scanning and repairing TypeScript projects.

## Scan check items

| ID | Category | Check Item | Severity |
|----|------|--------|--------|
| TS-01 | Bug | any type escape (function parameter or return value is any) | Medium |
| TS-02 | Bug | Unhandled Promise rejection | High |
| TS-03 | Bug | == instead of === (non-null check scenario) | Medium |
| TS-04 | Design | Very large components (>300 lines of React components) | Medium |
| TS-05 | Dedup | Many identical fetch/API calling patterns | Medium |
| TS-06 | Perf | useEffect missing dependency or too wide dependency | Medium |
| TS-07 | Perf | Large array in render map without memo | Low |

## SKIP rules (TypeScript specific)

| Conditions | Judgment | Reasons |
|------|------|------|
| Use interface instead of type (or vice versa) | SKIP | Style preference, does not affect functionality |
| Missing JSDoc but clear type signatures | SKIP | Types are documents |
| Use enum instead of union type | SKIP | Unless it causes bundle size problems |

## ECC enhancement rules

| ID | Category | Check Item | Severity |
|----|------|--------|--------|
| TS-08 | Safety | Bypass type checking using `as any` or `@ts-ignore` | High |
| TS-09 | Design | Function has more than 4 parameters (options object should be used) | Medium |
| TS-10 | Design | Nested callbacks beyond 3 levels (async/await should be used) | Medium |
| TS-11 | Safety | Unhandled null/undefined (missing optional chaining or null check) | Medium |
| TS-12 | Perf | Component props pass entire object instead of required fields | Low |

## Verification command
```bash
npx tsc --noEmit && npx eslint . && npm test
```
