---
paths: **/*.ts,**/*.tsx,**/*.js,**/*.jsx
---

# TypeScript and React review

## TS-01: Use type tooling for unsafe escapes (guideline)
Use the project's typescript-eslint no-explicit-any, ban-ts-comment and applicable type-aware no-unsafe checks. Narrow unknown data at its boundary. Third-party typing limitations may require a justified local assertion; as unknown as T does not add runtime validation.

## TS-02: Assign responsibility for Promise completion and failure (high)
Await a Promise, return it to a responsible caller, or handle failure at the appropriate terminal boundary. Returning a Promise is valid propagation. Empty catch handlers and void expressions do not by themselves handle rejection. Use no-floating-promises/no-misused-promises as partial evidence.

## TS-03: Use deliberate equality semantics (guideline)
Use ESLint eqeqeq according to the project contract. This rule permits explicit == null checks for null or undefined; an equivalent configuration is always with null ignored. Do not maintain a separate text scanner or report console statements under this ID.

## TS-04: Review components with mixed responsibilities (guideline)
Split components or hooks when independent responsibilities make the requested behavior difficult to maintain or test. A component's line count alone is not a refactoring requirement.

## TS-06: Keep Effects and their dependencies accurate (high)
First decide whether an Effect is needed to synchronize with an external system. Use react-hooks/exhaustive-deps and restructure the actual logic where appropriate. Add useCallback/useMemo only for a concrete stable-reference need, not as the default fix for broad dependencies.

## TS-07: Optimize rendering when there is demonstrated cost (guideline)
Use measurements or a concrete expensive path and consider the project's compiler and existing memoization. Minimal props may help a real memo boundary; passing a full object is not inherently a performance defect. Do not add memoization merely because a render maps an array.

## TS-11: Handle missing values according to the contract (high)
Use optional chaining, defaults or an early return only when absence is valid. Required data missing at runtime must fail clearly. strictNullChecks covers modeled types, not validation of arbitrary external input.

## TS-13: Reuse genuinely shared behavior (guideline)
Search relevant existing implementations before adding a component, hook or API helper. Compare contracts, error behavior, authentication, caching and cancellation before extracting shared code. Similar markup, class strings, counts or fixed directory names cannot prove the same responsibility.

## TS-14: Keep mocks aligned with affected contracts (high)
When changing an interface, inspect the actual affected mocks and callers. Use typed Vitest/Jest mock APIs and a type-check command that includes the test files. A complete mock needs its complete return contract; Partial makes fields optional and cannot prove completeness. Type compatibility does not establish equivalent behavior, so verify relevant runtime behavior too.
