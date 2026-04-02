---
name: "VibeGuard: Review"
description: "Structured code review - first run the guard to obtain the baseline, then review according to security → logic → quality → performance priority"
category: VibeGuard
tags: [vibeguard, review, code-review, security]
argument-hint: "<project directory or file path>"
---

<!-- VIBEGUARD:REVIEW:START -->
**Core Concept**
- Review is not to find faults, but to systematically verify code quality
- Stratified by priority: Security issues > Logic bugs > Code quality > Performance
- Each discovery comes with specific fix recommendations

**Steps**

1. **Get guard baseline**
   - Run `bash guards/<language>/check_*.sh <target_dir>` to get the current guard status
   - Record existing problems (no repeated reports)

2. **Determine the scope of review**
   - If a file path is specified: review the file
   - If a directory is specified: review recently modified files (`git diff --name-only`)
   - If no parameters: review the files in the current git staging area

3. **P0 — Security Review**
   - Refer to `vibeguard/rules/security.md`
   - Check OWASP Top 10 related questions
   - Check for key/credential leaks
   - Check input validation and sanitization

4. **P1 — Logical Correctness**
   - Boundary condition processing
   - Error handling integrity
   - Concurrency safety
   - Data consistency (multiple entry paths are consistent U-11~U-14)

5. **P2 — Code Quality**
   - Duplicate code detection (whether there is an existing implementation that can be reused)
   - Naming convention (refer to L2 naming constraints)
   - Exception handling (disable silent swallowing of exceptions L3)
   - File size (>800 line mark)
   - Refer to the corresponding language rule file

6. **P3 — Performance**
   - Performance issues on the hot path
   - N+1 query
   - Unnecessary memory allocation

7. **Goal-Backward, borrowed from GSD)**
   - From the user's perspective: What difference can users observe after these changes are completed?
   - Backward verification of third-level products:
     - L1 Existence: Do all declared/committed files and functions exist?
     - L2 Substantiveness: Is it a real implementation? Scan `todo!()`, `unimplemented!()`, empty function body, `pass #` and other stubs
     - L3 Wiring: Is the new code wired correctly? (Called, imported, covered by tests)
   - If L1/L2/L3 is found missing, report it as P1 logic problem

8. **Output review report**

   **Markdown format** (default):
   ```markdown
   ## Review Report

   ### Guard the baseline
   <Summary of guard script results>

   ### Discover
   | Priority | File:line number | Question | Suggestion |
   |--------|-----------|------|------|
   | P0     | ...       | ...  | ...  |

   ### Passed items
   - <Confirm that there are no problems>

   ### suggestion
   - <Improvement suggestions (optional)>
   ```

   **JSON format** (optional, convenient for trend comparison of check command consumption):
   ```json
   {
     "command": "review",
     "scope": "<review scope>",
     "findings": [
       {"priority": "P0", "file": "file:line", "issue": "...", "suggestion": "...", "ruleId": "RS-03"}
     ],
     "passedItems": ["No security holes", "..."],
     "verdict": "pass | warn | fail"
   }
   ```
   See `docs/command-schemas.md` for Schema details.

**Guardrails**
- It is not recommended to add unnecessary abstractions (L5)
- Adding a backward compatibility layer (L7) is not recommended
- When duplicate code is found, it is recommended to extend the existing implementation rather than create a new one (L1)
- AI generated tags are not included in review reports

**Reference**
- Security rules: `vibeguard/rules/security.md`
- Universal rules: `vibeguard/rules/universal.md`
- Language rules: `vibeguard/rules/<lang>.md`
<!-- VIBEGUARD:REVIEW:END -->
