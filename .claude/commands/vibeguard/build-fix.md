---
name: "VibeGuard: Build Fix"
description: "Build repair — read build errors, locate root causes, perform minimal repairs, and verify that the build passed"
category: VibeGuard
tags: [vibeguard, build, fix, error]
argument-hint: "<build command or error message>"
---

<!-- VIBEGUARD:BUILD-FIX:START -->
**Core Concept**
- The goal of build error fixing is to make the build pass, not to refactor the code
- Fix from the root cause, one fix may solve multiple errors
- Minimum change principle: only fix build errors, no additional improvements

**Steps**

1. **Catch build errors**
   - If the user provides error information: parse directly
   - If the user provides a build command: run the command to capture the output
   - If no parameters: try to detect the project type and run the corresponding build command
     - Rust: `cargo build 2>&1`
     - TypeScript: `npx tsc --noEmit 2>&1`
     - Go: `go build ./... 2>&1`
     - Python: `python -m py_compile <files> 2>&1`

2. **Parse error**
   - Extraction: file path, line number, error type, error message
   - Group by files
   - Identify dependencies between errors (A causes B)

3. **Locate the root cause**
   - Read the source file involved in the error
   - Distinguish between direct causes and root causes
   - Multiple errors may originate from the same root cause → Prioritize fixing the root cause

4. **Perform minimal repair**
   - Only fix build errors, no additional improvements (L5)
   - Do not use `@ts-ignore` / `# type: ignore` / `//nolint` bypass
   - Bypass type errors without `any` / `as any`
   - Solve problems that the standard library can solve without introducing new dependencies (U-06)

5. **Verification**
   - Rerun the build command to confirm zero errors
   - Run tests to confirm there are no regressions
   - Run type check confirmed passed

6. **Output repair report**

   ```markdown
   ## Build repair report

   ### Error summary
   - Total number of errors: N
   - Root factor: M
   - Number of files repaired: K

   ### Fix details
   | File:line number | Error | Fix |
   |-----------|------|------|
   | ...       | ...  | ...  |

   ### verify
   - Build: Pass/Fail
   - Test: pass/fail
   ```

**Guardrails**
- Don't change code style in fix (U-07)
- Not fixing unrelated issues all at once (U-09)
- Must verify that the build passes after fixing

**Reference**
- Universal rules: `vibeguard/rules/universal.md`
- Language rules: `vibeguard/rules/<lang>.md`
<!-- VIBEGUARD:BUILD-FIX:END -->
