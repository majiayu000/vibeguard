---
paths: **/*.ts,**/*.tsx,**/*.js,**/*.jsx
---

#TypeScript Quality Rules

## TS-01: any type escape (medium)
Function parameters or return values are any. Fix: Replace with a specific type or `unknown`, and use unknown after narrowing the type.

## TS-02: Unhandled Promise rejection (high)
Async function calls lack error handling. Fix: Add `await` + try/catch, or `.catch()` to all async calls.

## TS-03: == instead of === (medium)
Use relaxed equality for non-null check scenarios. Fix: changed to `===`. The null check scenario is available with `== null`.

## TS-04: Very large component > 300 lines (medium)
React component is too large. Fix: Split into subcomponents and custom hooks, with a single component not exceeding 300 lines.

## TS-05: Multiple identical fetch/API calling patterns (medium)
Fix: Extract public API client functions or hooks.

## TS-06: useEffect is missing a dependency or the dependency is too wide (medium)
Fix: Exactly declare dependent arrays. If the dependency is too wide, use useCallback/useMemo stable reference instead.

## TS-07: Large array in render map without memo (low)
Fix: cache map results with `useMemo`, or move array handling outside render.

## TS-08: Use `as any` or `@ts-ignore` to bypass type checking (high)
Fix: Replaced with correct type definition or type guard. Use `as unknown as T` when necessary and comment the reason.

## TS-09: Function has more than 4 parameters (medium)
Fix: merged into a single options object parameter.

## TS-10: Nested callbacks beyond 3 levels (medium)
Fix: Use async/await to flatten async chains instead.

## TS-11: Unhandled null/undefined (medium)
Missing optional chaining or null check. Fix: Use `?.`, `??` or an early guard return.

## TS-12: Component props pass the entire object instead of required fields (low)
Fix: Only pass the fields actually needed by the component to avoid unnecessary re-rendering.

## TS-13: Component/Hook function duplication (different names, same function) (high)
Multiple files define functionally equivalent React components or Hooks with different names. Common patterns:
- Duplication of UI primitives: FormField, InputGroup, FieldWrapper and equivalent functional components are independently defined in multiple places
- Table sorting is repeated: multiple table components each implement sortKey/sortDir status + sorting logic
- Query Hook template duplication: multiple useXxxDetail/useXxxList Hook duplication useQuery → standardized return structure

**Required before creating a new component/Hook**:
1. Search `components/ui/` and `components/common/` to see if there are already components with the same function
2. Search the `hooks/` directory to see if there is a Hook of the same pattern.
3. If you find a functionally equivalent implementation, reuse it instead of creating a new one.

Fix: Extract to `components/ui/` or `hooks/` shared directory, other files are imported instead.

## TS-14: The test mock is inconsistent with the real module shape (high)
`vi.mock()` / `jest.mock()` factory function returns `any` type, TypeScript cannot detect the deviation between mock shape and real module.
After refactoring the hook/module return value, the mock silently returns the old field name, and the test can still pass but the regression detection capability is lost.

**Must be used when refactoring the interface**:
1. Search all `vi.mock('modified module path')` and `jest.mock('modified module path')` calls
2. Update the mock return value to be consistent with the new shape
3. Prefer to use `satisfies` or type assertions to ensure shape safety:
   ```ts
   vi.mock('@/hooks/useDeals', () => ({
     useDeals: () => ({ deals: [], isLoading: false } satisfies Partial<ReturnType<typeof useDeals>>)
   }))
   ```

Fix: For all vi.mock/jest.mock calls in the grep project, confirm that the return value field name is consistent with the current export of the corresponding module.
