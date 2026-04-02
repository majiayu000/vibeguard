---
name: "VibeGuard: Interview"
description: "In-depth interviews with user needs before the start of major functions, mining boundary conditions and technical trade-offs, and outputting structured SPEC"
category: VibeGuard
tags: [vibeguard, interview, requirements, spec]
---

<!-- VIBEGUARD:INTERVIEW:START -->
**Core Concept** (from Anthropic official best practices)
- Failure of large functions often stems from unclear requirements rather than incorrect implementation
- AI proactively interviews users to uncover unconsidered edge cases and technical trade-offs
- Output structured SPEC after interview, it is recommended to execute in **new session** to get clean context

**Trigger condition**
- Involves the development of new functions/modules
- Requirements description is vague or incomplete
- Changes affecting multiple modules (complexity routing 6+ file level)

**Guardrails**
- No code modifications, only analysis and interviews
- Up to 4 rounds of interviews, 2-4 questions each, keep the pace tight
- Don’t ask obvious questions, **explore the difficulties that users didn’t expect**
- When the user says "you decide", the recommended solution is given and recorded

**Steps**

1. **Understand the initial requirements**
   - Read user requirement description ($ARGUMENTS or current context)
   - Quickly scan relevant code and understand existing architecture and constraints
   - Identify fuzzy points and undefined boundaries in requirements

2. **In-Depth Interview** (using AskUserQuestion tool)

   **Round 1: Functional Boundaries**
   - What are the core use cases? Which scenes are explicitly not allowed to be done?
   - Are there any existing implementations with similar functionality that I can refer to?

   **Round 2: Technology Implementation**
   - Performance/latency requirements? Data storage preferences?
   - What existing interfaces need to be compatible with?

   **Round 3: Boundary Cases**
   - How to deal with concurrency/race conditions? Expected behavior on error?
   - Downgrade strategy when data volume is large?

   **Round 4: Acceptance Criteria**
   - How do you count it as "done"? What test coverage is required?
   - Are there any performance benchmarks that must be passed?

   Dynamically adjust the question direction based on the previous round of answers. If you have covered enough in previous rounds, you can end the interview early.

3. **Generate SPEC**

   ```markdown
   # Feature Spec: <function name>
   ## Overview
   One sentence description + core value

   ## Functional requirements
   - FR-01: ...

   ## Non-functional requirements
   - NFR-01: Performance/Safety/Compatibility Requirements

   ## Technical Design
   ### Scope of influence
   - New: ...
   - Revise: ...
   ### Interface definition
   ### Data model changes

   ## Boundary cases
   - EC-01: ...

   ## Acceptance criteria
   - [ ] AC-01: ...
   ```

4. **Confirm and save**
   - Show SPEC to user for confirmation
   - Save to the project root directory `SPEC.md` (or user-specified path)
   - Remind users: **It is recommended to execute SPEC in a new session**, clean context implementation is more reliable

**Follow-up connection**
- In a new session: read SPEC.md → `/vibeguard:preflight` generate constraint set → implement by SPEC
<!-- VIBEGUARD:INTERVIEW:END -->
