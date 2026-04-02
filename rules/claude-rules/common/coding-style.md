
# General behavior constraint rules

## U-01: Do not modify public API signature (strict)
Public function signatures must not be modified unless the user explicitly requests breaking change and accepts a MAJOR version upgrade.

## U-02: Do not extract abstractions for code that appears only once (strict)
3 lines of repetition are better than 1 premature abstraction. Wait for the 3rd iteration before extracting.

## U-03: Don’t use macros to replace readable repeated code (strict)
Macros reduce readability and IDE support. Only allowed if there are >5 repetitions and the pattern is exactly the same.

## U-04: Do not add unrequired functionality (strict)
The bug fix scope is strictly locked and surrounding code will not be refactored.

## U-05: Don't delete seemingly "useless" code without confirming it first (strict)
Probably a WIP feature. Mark DEFER instead of delete.

## U-06: Do not introduce new dependencies to solve problems that the standard library can solve (strict)
Use the standard library first to avoid dependency bloat.

## U-07: Do not change code style in fixes (strict)
Style changes should be separated into separate commits.

## U-08: Do not skip verification step (strict)
Each fix must pass lint + test independently.

## U-09: Don’t commit multiple unrelated fixes at once (strict)
Atomic commit, convenient for revert.

## U-10: Don’t guess user intent (strict)
If unsure, mark it as DEFER or confirm with the user.

## U-15: Immutability first
Create new objects instead of modifying existing ones. Function parameters are treated as read-only.

## U-16: File size control
200-400 lines typical, 800 lines upper limit. More than 800 rows must be split.

## U-17: Error handling complete
Comprehensively handle error paths and prohibit silent swallowing of exceptions. Provide user-friendly error messages.

## U-18: Input validation
Validate all user input at system boundaries. Internal code trust framework guarantees.

## U-19: Repository mode
Data access is encapsulated into the Repository layer, and business logic does not directly operate the database.

## U-20: API response format is unified
Unified envelope structure `{ data, error, meta }`. Error code standardization.

## U-21: Submission message format
`<type>: <description>`, type is feat/fix/refactor/docs/test/chore.

## U-22: Test coverage (strict)
Minimum 80% line coverage for new code, 100% critical path.

**Mechanized inspection (Agent execution rules)**:
- After modifying the source file, check whether there is a corresponding `*.test.*` or `*.spec.*` file
- If it does not exist and the file contains business logic (non-pure types/constants/styles), mark it as DEFER and inform the user
- When refactoring involves >3 files, at least supplement the single test of the modified core path
- When refactoring the hook/module interface, synchronously update all test mock shapes that reference the module (see TS-14)

## U-23: Disable silent downgrade
Unsupported policies/configurations must be explicitly reported as an error or marked DEFER and must not be automatically downgraded to the default policy.

## U-24: No aliases allowed
Function/type/command/directory aliases are prohibited. If the old name is found, directly replace it in full and delete the old name.

## U-25: Build failure repair priority (strict)
Once a build error is detected, the build must be fixed before continuing with other edits. It is forbidden to continue adding code when the build fails.

**Mechanized inspection (Agent execution rules)**:
- When you receive a build error warning after editing the source code, the next step must be to fix the build error
- After 3 consecutive build failures, run the complete build command (`cargo check` / `npx tsc --noEmit` / `go build ./...`) to see the full picture
- Locate the root cause (usually type mismatch, missing import, interface change out of sync), fix it in one go instead of guessing one by one
- It is prohibited to add irrelevant function codes during the build red light state.

## U-26: Declaration-Execution Integrity (strict)
After declaring the framework components (Config/Trait/Persistence Layer/State Management), startup integration must be completed. "Declared but not wired" is prohibited.

**CHECKLIST**:
- Config structure → startup code must call `load()` instead of `Default::default()`
- Trait declaration → there must be at least one `impl` + startup registration point (registry/builder)
- Persistence methods (save/load/persist/restore) → startup code must call to restore state
- New fields added to AppState/Context → must be initialized at all construction points

**Repair Mode**:
1. Audit all declaration points (`rg "struct.*Config"` / `rg "trait "` / `rg "fn.*(save|load|persist)"`)
2. Verify the corresponding startup registration (`build_app_state()` / `main()` / `init()` / `new()`)
3. Add missing registration call
4. Implement silent fallback (missing configuration → use default value, start without crash)

**Anti-Pattern**:
- SkillStore has a `discover()` method but it is never called when starting → skills are lost after restarting
- RulesConfig is loaded from TOML but the consumer calls `Default::default()` → the configuration does not take effect
- ThreadManager has `persist()` method but never calls it → dead code
- GC receives `project_root` but does not propagate to subtasks → functionality downgraded
