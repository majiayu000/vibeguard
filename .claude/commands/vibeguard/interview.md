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
- **Code examples over prose**: every constraint/rule in the SPEC should include a concrete code snippet (good vs bad) rather than abstract text. Show the pattern, don't just name it.
  (来源: Addy Osmani "How to write a good spec for AI agents", 2026-04)

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

   ## Three-Layer Boundaries
   (来源: Addy Osmani, GitHub 2500+ agent 配置文件分析)

   ### ✅ Always do
   - AB-01: [必须无条件遵守的规则，附代码示例]

   ### ⚠️ Ask first
   - AF-01: [需要确认后才能执行的决策]

   ### 🚫 Never do
   - AN-01: [硬禁止项，附代码示例]

   ## Six Core Areas Coverage
   标记每个区域是否适用于当前任务。[APPLICABLE] 的区域必须包含至少一条具体规则 + 代码示例。

   - [ ] Commands: [APPLICABLE] / [N/A]
   - [ ] Testing: [APPLICABLE] / [N/A]
   - [ ] Project structure: [APPLICABLE] / [N/A]
   - [ ] Code style: [APPLICABLE] / [N/A]
   - [ ] Git workflow: [APPLICABLE] / [N/A]
   - [ ] Boundaries: [APPLICABLE] / [N/A]

   ## Boundary cases
   - EC-01: ...

   ## Acceptance criteria
   - [ ] AC-01: ...
   ```

4. **Confirm and save**
   - Show SPEC to user for confirmation
   - Verify: Three-Layer Boundaries 每层至少有 1 个条目
   - Verify: Six Core Areas 每个区域都标注了 [APPLICABLE] 或 [N/A]
   - Save to the project root directory `SPEC.md` (or user-specified path)
   - Remind users: **It is recommended to execute SPEC in a new session**, clean context implementation is more reliable

**Follow-up connection**
- In a new session: read SPEC.md → `/vibeguard:preflight` generate constraint set → implement by SPEC
- Three-Layer Boundaries feed directly into preflight constraint generation (Always → hard constraints, Never → guard violations)
<!-- VIBEGUARD:INTERVIEW:END -->
