---
name: "VibeGuard: Learn"
description: "Dual-mode learning: (A) Extract guard rules from errors (B) Extract reusable skills from discoveries. Automatic mode routing."
category: VibeGuard
tags: [vibeguard, learn, feedback, improvement, skill-extraction]
argument-hint: "<Error description | 'extract' extract experience | empty = automatic judgment>"
---

<!-- VIBEGUARD:LEARN:START -->

## Core Concept

- Agent's mistakes are not the end, but a signal to improve the defense system.
- When the Agent discovers non-obvious solutions, it should be extracted into reusable knowledge
- Goal: **Mistakes will no longer be repeated + Experience will no longer be forgotten**

## Pattern routing

Automatically select a mode based on parameters and context:

| input | mode |
|------|------|
| User describes error/bug/guard failure | **Mode A**: error analysis → output guard/hook/rule |
| User said "extract" / "Extract experience" / "What was learned" | **Mode B**: Experience extraction → Output SKILL.md |
| Stop hook automatically triggered (no parameters) | Evaluate first → select A or B as needed |
| Session with both bug fixes and non-obvious findings | **A + B both executed** |

---

## Mode A: Error analysis (defense-oriented)

> Learn from mistakes and generate guard rules or hooks to prevent similar mistakes from happening again.

**Trigger scene**
- Agent created duplicate files/types (L1 failed)
- Agent hard-coded path/port/URL (L4 failure)
- Agent introduces data splitting (multiple entries are inconsistent)
- Agent is unnecessarily over-designed (L5 failure)
- The guard script has false positives or false negatives
- Any recurring Agent error patterns

**Guardrails**
- No direct fixes to the business code — only improvements to VibeGuard itself
- New rules must be verifiable (can write scripts to detect or test assertions)
- Don’t overgeneralize — one error pattern corresponds to one precise rule

**Steps**

1. **Automatic pattern recognition (extracted from events.jsonl + learn-digest.jsonl)**
   - Read `~/.vibeguard/projects/<hash>/events.jsonl` and analyze recent event records
   - Read `~/.vibeguard/learn-digest.jsonl` to obtain the cross-session signals recognized by GC regular learning (repeated_warn / chronic_block / hot_files / slow_sessions / warn_escalation)
   - Extract high-frequency warn patterns: similar problems that have been warned many times but still reoccur
   - Extract similar operations that are repeatedly blocked: identify the operation patterns in which the agent repeatedly hits the wall
   - Group by hook + reason to output top 5 high-frequency problems
   - Use recognized patterns as input for subsequent analysis (no longer relying solely on user descriptions)

2. **Collect error context**
   - What error did the user describe? (parameters `$ARGUMENTS` or conversation context)
   - Combined with the automatic identification results in step 1, confirm whether it is a known high-frequency problem
   - In which file/module does the error occur?
   - Specific manifestations of errors (diff, screenshots, error messages)
   - How many times has this error occurred?

3. **Root cause analysis (5-Why)**
   - **Surface reason**: What wrong operation did the Agent do?
   - **Direct Reason**: Why didn't the existing guards stop him?
     - Guard script does not exist? → New guards needed
     - Guards present but pattern matching not enough? → Enhanced guard
     - Hook does not cover this operation? → Add new hook rules
     - Not mentioned in the rules file? → Supplementary rules
   - **Root Cause**: What is missing at the system level?
     - Missing documentation/map?
     - Lack of mechanized inspection?
     - Constraints not specific enough?

4. **Determine type of improvement**

   | Improvement type | Applicable scenarios | Output |
   |----------|----------|------|
   | New guard script | New code pattern detection required | `guards/<lang>/check_xxx.sh` |
   | Enhance existing guards | Missing detection of existing guards | Modify scripts under `guards/` |
   | New hook rules | Need to intercept before/after the operation | Modify the script under `hooks/` |
   | New rule entry | Supplementary judgment criteria required | Modify the rules file under `rules/` |
   | New constraints to CLAUDE.md | Constraints that need to be globally effective | Modify `vibeguard-rules.md` |

5. **[Stop] Confirm improvement plan**
   - Display the new rules/hook content that will be written soon
   - Use AskUserQuestion to ask the user to confirm before continuing
   - Prevent automatically generated rules from being incorrect

6. **Implement improvements**

   **New Guard Script**:
   - Refer to the template of `guards/rust/check_unwrap_in_prod.sh`
   - Must include: `--strict` mode, `set -euo pipefail`, exclude tests/
   - Output format: `[ID] Problem description` + repair method (remediation)
   - Register to `/vibeguard:check` command

   **Enhance existing guards**:
   - Run existing guards first to confirm false negatives
   - Added new detection mode
   - Make sure not to break existing detections

   **New hook rules**:
   - PreToolUse hook is used to prevent operations (block)
   - PostToolUse hook is used for post-event warnings (warn)
   - Each block message must contain an alternative
   - Register to `setup.sh`

   **New Rule Entry**:
   - Assign new ID (RS-XX/U-XX)
   - Contains: category, inspection items, severity, repair mode
   - Added to FIX/SKIP judgment matrix

7. **Pattern recognition and rule generation**

   **Error pattern classification**
   | Patterns | Characteristics | Generate rule types |
   |------|------|-------------|
   | Repeated creation | Create new files multiple times with the same function | Guard script (detect similar file names/function names) |
   | Path illusion | Editing/referencing non-existent files | Hook rules (pre-edit checks for file existence) |
   | API illusion | Calling non-existent methods/fields | Rule entries (labeled real API list) |
   | Over-engineering | Adding unnecessary abstraction layers | Constraint items (enhancing the minimum change principle) |
   | Data splitting | Multiple entries hard-coded with different paths | Guard script (cross-entry path consistency check) |
   | Naming confusion | Multiple names for the same concept | Naming specification entries + alias detection |

   **Rule template generation**
   - Extract detection patterns (regex/AST/file structure) from error instances
   - Generate a guard script draft, including: detection logic, exclusion conditions, and repair suggestions
   - Output to `guards/<lang>/` or `hooks/` directory

8. **Verification improvements**
   - Use original error scenarios to verify that new guards/hooks can detect the problem
   - Run all existing guards to confirm there are no regressions
   - Update guard ID index (`vibeguard-rules.md`)

9. **Output learning report**

   ```markdown
   # VibeGuard Learn Report (Mode A)

   ## Error description
   <Brief error description>

   ## Root cause analysis
   - Superficial reasons:...
   - Direct cause:...
   - root cause:...

   ## Improvements
   - [ ] <improvement type>: <specific description>

   ## Verification results
   - New guard detection passed: ✓/✗
   - No return of existing guards: ✓/✗

   ## Defense system changes
   - Number of guards: N → N+1
   - Number of Hook rules: M → M+1
   - Number of rule entries: K → K+1
   ```

---

## Mode B: Experience extraction (accumulation direction)

> Extract reusable knowledge from non-obvious findings and save it as a Skill file so that it can be automatically called when encountering similar problems in the future.
> Source of inspiration: Claudeception (Voyager skill library + Reflexion self-reflection)

**Trigger scene**
- Debugging took >10 minutes, solution not found in documentation
- The error message is misleading and the actual root cause is different from the appearance.
- Discovered tool/framework limitations and workarounds through trial and error
- Discovered project-specific configuration/architectural patterns
- It took many attempts to find an effective solution

**Quality Gating (all 4 must be met)**

| Standard | Definition | Counterexample |
|------|------|------|
| **Reusable** | Can be used for similar tasks in the future | "This variable name is typed incorrectly" |
| **Non-trivial** | It takes exploration to find out, not just checking the documentation | "npm install installation dependencies" |
| **Specific** | Can describe precise trigger conditions and solution steps | "React sometimes reports errors" |
| **Verified** | The solution has been actually tested, not a theoretical speculation | "It should be solved with XX" |

**Steps**

1. **Self-Assessment**

   Answer the following questions (yes to any one to continue):
   - Did you just cover non-obvious debugging/troubleshooting?
   - Is the solution reusable for similar scenarios in the future?
   - Did you discover knowledge that was not covered by the documentation?
   - Is the error message misleading?
   - Was the solution found through trial and error?

   All are "No" → skip, do not extract.

2. **Remove duplicates**

   Search for existing Skills before extracting:

   ```bash
   # Search path (first project level, then user level)
   SKILL_DIRS=(".claude/skills" "$HOME/.claude/skills")

   #Search by keyword
   rg -i "keyword1|keyword2" "${SKILL_DIRS[@]}" 2>/dev/null

   # Search by error message
   rg -F "exact error message" "${SKILL_DIRS[@]}" 2>/dev/null
   ```

   **Deduplication decision table**

   | Search results | Actions |
   |----------|------|
   | Unrelated | New Skill |
   | Same trigger + same scheme | Update existing (version + minor) |
   | Same trigger + different root causes | New, two-way addition `See also:` |
   | Same field + different triggers | Update existing, add "Variations" section |
   | Existing but outdated/wrong | Marked as obsolete, replaced by new one |

3. **Extract knowledge**

   This analysis found:
   - what is the problem?
   - What parts of the solution are non-obvious?
   - What do you need to know to solve it faster next time you encounter it?
   - What is the trigger (error message, symptom, scenario)?

4. **Conditional Web Research**

   The following situations require search verification:
   - Best practices involving specific technologies/frameworks
   - APIs/Tools that may change after 2025
   - Not sure if the current solution is a recommended practice

   Search strategy:
   - Official documentation: `"[Technical][Functional] official docs 2026"`
   - Best practices: `"[Technology][Question] best practices 2026"`
   - FAQ: `"[Technology][Error Message] solution 2026"`

   Project-internal patterns, clear context-specific scenarios, stable general programming concepts → Skip search.

5. **Structured as SKILL.md**

   ```markdown
   ---
   name: descriptive-kebab-case-name
   description: |
     [Precise description, including: (1) What problem is solved (2) Triggering condition (error message/symptom)
     (3) Technologies/frameworks involved. Start with "Use when:" to list usage scenarios]
   author: Claude Code
   version: 1.0.0
   date: YYYY-MM-DD
   ---

   # [Skill name]

   ## Problem
   [Problem description: What are the pain points? Why not obvious? ]

   ## Context / Trigger Conditions
   - [Exact error message]
   - [Observable Symptoms/Behaviors]
   - [Environmental conditions (framework/tools/platform)]

   ## Solution
   ### Step 1: ...
   ### Step 2: ...
   ### Step 3: ...

   ## Verification
   [How to confirm that the plan is effective]

   ## Example
   **Scenario**: [Specific case]
   **Before**: [Error status]
   **After**: [status after repair]

   ## Notes
   - [Notes, boundary conditions]
   - [When this Skill should not be used]
   - [See also: Related Skills]

   ## References
   - [Source link (web research if available)]
   ```

6. **Save Location Decision**

   | Type | Location | Description |
   |------|------|------|
   | Project specific | `.claude/skills/[name]/SKILL.md` | Only useful for the current project |
   | Common across projects | `~/.claude/skills/[name]/SKILL.md` | Available to all future projects |

7. **[Stop] Confirm and save**
   - Display the generated SKILL.md content
   - Ask user to confirm using AskUserQuestion
   - Write to file after confirmation

8. **Output extraction report**

   ```markdown
   # VibeGuard Learn Report (Mode B)

   ## Discovery description
   <This non-obvious discovery>

   ## Extracted Skill
   - Name: [skill-name]
   - Location: [file path]
   - Version: 1.0.0

   ## Quality Check
   - Reusable: ✓
   - Non-trivial: ✓
   - Specific: ✓
   - Verified: ✓
   - No duplication: ✓
   - No sensitive information: ✓

   ## Skill life cycle
   Create → iterate (version +minor when new scenes are discovered) → discard (mark when underlying changes) → archive
   ```

---

## Anti-pattern

| Anti-Pattern | Description |
|--------|------|
| **Over-extraction** | Not every task is worth extracting, and mundane operations do not require Skill |
| **Description is vague** | "Help solve database problems" will not be hit by semantic matching |
| **Unverified solutions** | Only extract actual tested solutions, not theoretical speculations |
| **Duplicate Documentation** | Don't rewrite the official documentation, link to it and fill in the missing parts |
| **Expired Knowledge** | Skill must have version and date, and will be marked as discarded when expired |
| **Leaking Sensitive Information** | Skills are prohibited from containing keys, internal URLs, and API keys |

## Design principles

- **Precision first**: One rule solves one type of problem, without general "pay attention to code quality"
- **Mechanization first**: If you can write a script for detection, write a script, and do not rely on agents to comply consciously.
- **Error message is the repair command**: The guard output should tell the agent HOW to fix, not just WHAT is wrong
- **Minimal Change**: Don’t rewrite the entire guard system just because of an edge case
- **Description is retrieval**: The description of a Skill directly determines whether it can be hit by semantic matching.

## Reference

- VibeGuard guard script template: `vibeguard/guards/`
- Hook script template: `vibeguard/hooks/`
- Rules file: `vibeguard/rules/`
- Rule index: `vibeguard/claude-md/vibeguard-rules.md`
- Skill template: `templates/skill-template.md`
- Academic references: Voyager (skill libraries), CASCADE (meta-skills), Reflexion (self-reflection)
<!-- VIBEGUARD:LEARN:END -->
