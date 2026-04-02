---
name: "VibeGuard: ExecPlan"
description: "Long-term task execution plan — generates self-contained execution documents from SPEC, supports cross-session recovery"
category: VibeGuard
tags: [vibeguard, execplan, long-horizon, planning]
---

<!-- VIBEGUARD:EXEC-PLAN:START -->
**Core Concept** (from OpenAI Harness Engineering)
- Long-term tasks require self-contained execution documents that can be resumed in new sessions by themselves
- Progress is the only chapter that allows checklist, the rest are described in prose
- Decision Log records all decisions that deviate from SPEC to ensure traceability
- ExecPlan is a living document that is continuously updated with execution

**Three modes**

| Mode | Usage | Description |
|------|------|------|
| `init` | `/vibeguard:exec-plan init [spec path]` | Generate ExecPlan from SPEC |
| `update` | `/vibeguard:exec-plan update <execplan path>` | Append Discovery/Decision/completion status |
| `status` | `/vibeguard:exec-plan status <execplan path>` | View Progress progress summary |

**Trigger condition**
- SPEC generated and confirmed via `/vibeguard:interview`
- Tasks expected to be completed across 2+ sessions
- Scenarios where execution context needs to be restored across sessions

**Guardrails**
- `init` mode does not make any code modifications, only generates documentation
- `update` mode only modifies the ExecPlan file itself
- Does not replace preflight - ExecPlan defines "what to do", preflight defines "what not to do"

---

### Mode: init

Generate ExecPlan files from SPEC.

**Steps**

1. **Read SPEC**
   - If spec path ($ARGUMENTS) is provided, read the file
   - If not provided, search for `SPEC.md` in the project root directory
   - If there is no SPEC, prompt the user to run `/vibeguard:interview` first

2. **Analyze SPEC and break down milestones**
   - Extract milestones from SPEC functional requirements (FR-XX)
   - Each milestone contains 1-3 specific steps
   - Identify dependencies between milestones

3. **Scan project context**
   - Identify languages/frameworks and key entry files
   - Check if there is a preflight constraint set to reference
   - Document existing code locations related to SPEC

4. **Generate ExecPlan**
   - Populate 8 chapters by template (`workflows/plan-flow/references/execplan-template.md`)
   - Purpose extracted directly from the SPEC overview
   - Progress is mapped to a milestone list with checkbox
   - Concrete Steps aligns the Step format of plan-template.md (status/target/file/change/test/judgment)
   - **Nyquist Rule**: Each Step must contain the `verify_cmd` field - a verification command that can be executed within 60 seconds (such as `cargo test --lib`, `curl localhost:8080/health`). Steps that cannot be verified within 60s are marked as `unverifiable` and need to be split or supplemented with verification methods.
   - Validation converted from SPEC acceptance criteria (AC-XX)
   - Decision Log is initially empty and records the selection decisions during generation.

5. **Save and Confirm**
   - Save to `<project name>-execplan.md` (project root directory)
   - Display Progress and Concrete Steps summaries for user confirmation
   - Use AskUserQuestion to confirm if adjustments are needed

---

### Mode: update

Appends discoveries and status changes during execution.

**Steps**

1. **Read ExecPlan**
   - Read the ExecPlan file specified by $ARGUMENTS
   - Parse the current Progress and Concrete Steps status

2. **Identify update type**
   - Step completion: Update the Step status to `completed` and add the Step Completion Log
   - New Discovery: Append to Surprises table
   - Decision changes: Append to Decision Log table
   - Milestone completed: Check the corresponding checkbox in Progress

3. **Perform update**
   - Modify the corresponding section in the ExecPlan file
   - Automatically mark the next `pending` step as `in_progress` if the step is completed
   - If all milestones are completed, change the plan status to `completed`

4. **Show update summary**
   - Output changed chapter content
   - If there are Surprises, the highlight prompt may need to adjust the subsequent steps

---

### Mode: status

View a summary of execution progress.

**Steps**

1. **Read ExecPlan**
   - Read the ExecPlan file specified by $ARGUMENTS

2. **Output progress report**
   ```
   ExecPlan: <task name>
   Status: active
   Progress: 2/5 Milestone Completed (40%)

   [x] M1: <description>
   [x] M2: <description>
   [ ] M3: <description> ← current
       Step C1: completed
       Step C2: in_progress
       Step C3: pending
   [ ] M4: <description>
   [ ] M5: <description>

   Recent Decisions: D3 — <Decision Summary>
   Unexpected discovery: 1 outstanding
   ```

**Follow-up connection**
- Full pipeline: `/vibeguard:interview` → SPEC → `/vibeguard:exec-plan init` → `/vibeguard:preflight` → Execute → `/vibeguard:exec-plan update`
- ExecPlan and preflight are complementary: ExecPlan defines the execution path, and preflight defines the protection boundary
- New session recovery: read ExecPlan → `/vibeguard:exec-plan status` → continue execution

**Reference**
- ExecPlan template: `workflows/plan-flow/references/execplan-template.md`
- Integration instructions: `workflows/plan-flow/references/execplan-integration.md`
- Plan-flow step format: `workflows/plan-flow/references/plan-template.md`
<!-- VIBEGUARD:EXEC-PLAN:END -->
