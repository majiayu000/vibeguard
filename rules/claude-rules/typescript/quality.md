---
paths: **/*.ts,**/*.tsx,**/*.js,**/*.jsx
---

# TypeScript Quality Rules

## TS-01: `any` type escape (medium)
Function parameters or return values use `any`. Fix: replace it with a concrete type or `unknown`, then narrow `unknown` before use.

## TS-02: Unhandled Promise rejections (high)
Async calls lack error handling. Fix: use `await` plus `try/catch`, or add `.catch()`.

## TS-03: `==` instead of `===` (medium)
Loose equality is used outside explicit null checks. Fix: switch to `===`. `== null` remains acceptable for null/undefined checks.

## TS-04: Oversized component larger than 300 lines (medium)
React component is too large. Fix: split it into smaller components and custom hooks so each component stays under 300 lines.

## TS-05: Repeated fetch / API call patterns across the codebase (medium)
Fix: extract a shared API client helper or hook.

## TS-06: `useEffect` has missing or overly broad dependencies (medium)
Fix: declare the dependency array precisely. If dependencies are too broad, stabilize them with `useCallback` / `useMemo`.

## TS-07: Large arrays are mapped during render without memoization (low)
Fix: cache the mapped result with `useMemo`, or move the array transformation out of render.

## TS-08: Bypassing type checks with `as any` or `@ts-ignore` (high)
Fix: replace the bypass with correct types or type guards. If absolutely necessary, use `as unknown as T` and explain why.

## TS-09: Functions with more than 4 parameters (medium)
Fix: combine arguments into a single options object.

## TS-10: Callback nesting deeper than 3 levels (medium)
Fix: flatten the async chain with async/await.

## TS-11: Unhandled `null` / `undefined` (medium)
Missing optional chaining or null guards. Fix: use `?.`, `??`, or an early guard return.

## TS-12: Passing full objects as component props instead of only required fields (low)
Fix: pass only the fields the component actually needs to avoid unnecessary re-renders.

## TS-13: Duplicate component or hook behavior under different names (high)
Multiple files define React components or hooks with equivalent behavior but different names. Common patterns:
- Duplicate UI primitives: `FormField`, `InputGroup`, `FieldWrapper`, and similar components recreated in multiple places
- Duplicate table sorting state: multiple tables each reimplement `sortKey` / `sortDir` logic
- Duplicate query hook templates: multiple `useXxxDetail` / `useXxxList` hooks repeat the same `useQuery` pattern and return structure

**Before creating a new component or hook, you must**:
1. Search `components/ui/` and `components/common/` for an equivalent component.
2. Search `hooks/` for an existing hook with the same pattern.
3. If an equivalent implementation exists, reuse it instead of creating a new one.

Fix: extract the shared implementation to `components/ui/` or `hooks/`, then convert other files to imports.

## TS-14: Test mocks drift from the real module shape (high)
`vi.mock()` and `jest.mock()` factory functions often return `any`, so TypeScript cannot tell when the mock shape drifts from the real module. After a hook or module refactor, a stale mock can keep returning old field names, the test still passes, and regression coverage silently disappears.

**When refactoring an interface, you must**:
1. Search every `vi.mock('path')` and `jest.mock('path')` call for the module you changed.
2. Update each mock return value to match the new shape.
3. Prefer `satisfies` or typed assertions to keep the mock shape honest:
   ```ts
   vi.mock('@/hooks/useDeals', () => ({
     useDeals: () => ({ deals: [], isLoading: false } satisfies Partial<ReturnType<typeof useDeals>>)
   }))
   ```

Fix: grep all `vi.mock` / `jest.mock` call sites and confirm the returned field names still match the current export shape.
