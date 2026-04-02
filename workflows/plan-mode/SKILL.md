---
name: plan-mode
description: Use when the user asks to enter Plan mode, says /prompts:plan or /plan, or wants a structured execution plan written to plan/.
---

# Plan Mode

## Trigger and target

This skill is enabled when the user explicitly requests to enter "Plan mode" or enters `/prompts:plan` / `/plan`. Treat the task description given by the user as `$ARGUMENTS` (if the user directly enters `/prompts:plan <description>`, then `<description>` will be `$ARGUMENTS`).

Goal: Develop a implementable and traceable technical execution plan for the task description `$ARGUMENTS` in the current working directory, and save the plan to the `plan/` directory of this project.

> Note: This skill only takes effect when the user explicitly triggers Plan mode and does not affect normal conversations.
> In actual use, you can pass:
>
> - Enter `/` and select `/prompts:plan` in the pop-up window; or
> - Configure shortcut keys in the terminal and automatically enter `/prompts:plan` to obtain a one-click experience similar to "/plan".

## 1. Overall behavioral agreement (must be observed)

1. You are the planning assistant within the project. You are only responsible for "thinking about what to do" and producing a structured plan. You do not directly change the code on a large scale.
2. Every time you enter Plan mode, reasoning and disassembly are completed **internally** first, and then the final structured plan is output:
   - Directly use the built-in reasoning of the model to complete task disassembly;
   - **Do not ask for or output** a complete chain of thinking/step-by-step reasoning details (chain-of-thought); only give "executable plan + key assumptions/trade-offs".
3. The granularity of the plan should be adaptive with the complexity (rather than a fixed “number of thinking steps”):
   - Simple: 3-5 steps, clearly define where to change and how to verify;
   - medium: 5–8 steps, including testing/regression and risk points;
   - Complex: 8–10 steps (split phases if necessary), including milestones, rollback/downgrade ideas and dependency coordination.
4. After you finish thinking, you need to sort out a concise and executable plan, and try to implement the plan into a file by default (see "4. Plan document implementation specifications").
5. If you cannot write files or call shell due to approval/policy restrictions, explain the reason in your answer and at least give the complete plan text.

## 2. Complexity judgment and planning depth specification

Before calling thinkplanning, the tasks are ranked according to `$ARGUMENTS` and the current context:

- simple：
  - Minor fixes whose scope is limited to a single file/function;
  - The number of steps is expected to be < 5;
  - No cross-service/cross-system impact.
- medium：
  - Involves multiple files/modules, or requires certain design choices (API changes, data structure adjustments, etc.);
  - Requires supplementary testing and simple regression verification.
- complex：
  - Involving cross-services or multiple subsystems (such as front-end and back-end, multiple microservices);
  - Or bring about architectural/performance trade-offs;
  - Or migration, grayscale release, etc. are required.

Planning depth requirements:

  - Directly use the built-in reasoning of the model to do multi-step thinking instead of improvising plans directly in the message;
  - The degree of thinking can be increased/decreased as needed during the thinking process (for example, if more sub-problems are found, add 2-4 steps) until the plan is detailed enough and implementable, then end thinking;
  - Does not require or output complete chain-of-thought details; only use the results to organize a structured plan.

## 3. In-dialogue output format

In Plan mode, your answer should use a fixed structure:

```markdown
Task: <Summarize the current task in one sentence (you can use $ARGUMENTS or your understanding)>

Plan:
- Phase 1: <Step 1, 1–2 sentences, describing the goal rather than implementation details>
- Phase 2: <Step 2>
- Phase 3: <Step 3>
...(maximum 8–10 steps, subdivided if necessary)

Key Decisions:
- <Use 2–4 bullets to summarize the key conclusions/trade-offs drawn from the thinking plan>

Risks:
- <Risk 1 (e.g. data security, performance, stability, etc.)>
- <Risk 2 (e.g. dependence on other teams/services, environment restrictions, etc.)>

Plan File:
- Path: `plan/<the file name you actually created>.md`
- Status: <Created and written / Unable to create (specify reason)>
```

If `$ARGUMENTS` is empty or not specific enough, you can briefly clarify the requirements in 1-2 sentences before planning, but do not get stuck in long questions.

## 4. Plan file implementation specifications (plan/*.md)

For each Plan mode conversation, try to create a new Plan file for the current task and use a unified Markdown structure to facilitate subsequent retrieval and tool processing.

1. Directory and file name
   - Directory: Use the current working directory as the root and create the `plan/` directory in it;
   - File name suggestion: `plan/YYYY-MM-DD_HH-mm-ss-<slug>.md`, where:
     - The timestamp part can be obtained through the methods available in the current system:
       - In a Unix-like environment, you can use: `date +"%Y-%m-%d_%H-%M-%S"`;
       - In Windows PowerShell, you can use: `Get-Date -Format "yyyy-MM-dd_HH-mm-ss"`;
       - If there is another more suitable method, you can choose it yourself, as long as the timestamp in the file name is monotonous and readable.
     - `<slug>` is a short identifier of the task extracted and normalized from `$ARGUMENTS`. Suggested rules:
       - Take some keywords or the first few words from the task description and remove the blanks;
       - Convert to lowercase;
       - Normalize non-alphanumeric characters to `-` and compress consecutive `-`;
       - Truncate to a reasonable length (e.g. 20–32 characters) to avoid overly long file names;
       - Remove the leading and trailing `-`; if it ends up being empty, it will degenerate into a general placeholder (such as `task` or `plan`).
   - Ensure that existing files are not overwritten. If the file already exists, append `<slug>` or a short suffix (such as `-1`, `-2`) to the end of the file name.

2. Plan file content structure (with special style metadata header)

When writing a file, a YAML-style metadata header (frontmatter) must be used at the top of the file, separated from the text by `---` to facilitate human eye recognition and tool parsing. Example:

```markdown
---
mode: plan
cwd: <current working directory, for example /Users/xxx/project>
task: <task title or summary (usually from your summary of $ARGUMENTS)>
complexity: <simple|medium|complex>
planning_method: builtin
created_at: <ISO8601 timestamp or date output>
---

# Plan: <Task brief title>

Task Overview
<Describe the context and goals of the task in 2–3 sentences. >

Plan
1. <Step 1: Describe in one sentence what to do and why>
2. <Step 2>
3. <Step 3>
...(expand based on complexity, generally 4–10 steps)

Risks
- <Risk or Caution 1>
- <Risk or Caution 2>

References
- `<file path:line number>` (e.g. `src/main/java/App.java:42`)
- Other useful links or instructions
```

Require:

- The metadata header must be located at the beginning of the file, in the YAML form wrapped with the above `---`, and clearly separated from the body text;
-Field names remain snake_case (such as `planning_method`) to facilitate script parsing;
- If some fields cannot be determined temporarily (such as complexity), you can use your current best judgment and do not leave the field names blank.

3. Writing method and failure handling

- Use the shell of the current platform to execute the command in the working directory to create the `plan/` directory and write the file. Be careful to avoid using commands that are only applicable to a single platform:
  - In a Unix-like environment, you can use: `mkdir -p plan`;
  - In Windows PowerShell, you can use: `New-Item -ItemType Directory -Force -Path plan`;
  - Then write the Markdown content to the new file using a method appropriate for the current shell (redirect, heredoc, `Set-Content` / `Out-File`, etc.).
- After successful writing, clearly inform the user in the conversation:
  - actual file path;
  - Whether to include PLAN_META block and full plan content.
- If the file cannot be created/written due to approval/policy restrictions or other errors:
  - Give reasons in your answer;
  - Still output the complete plan text, ensuring that the user can manually copy it to a file.

## 5. Recognition and cooperation when Plan mode is triggered multiple times in the same session

In a Codex session, the user may trigger Plan mode multiple times, for example:

- First time: `/prompts:plan Help me design an implementation plan for XXX`
- The second time: `/prompts:plan The previous design is not reasonable, I want to make adjustments` (or the user triggers the same prompt again through shortcut keys)

You need to determine whether to "continue the same Plan" or "create a new Plan" based on the user's intention, and choose to read or create a new Plan file accordingly.

1. Identification rules for the same Plan (the default priority is to consider "the same Plan")
   - If this is the first time in this session that you have entered Plan mode: Create a new Plan file.
   - If there is already a current Plan in this session (you have output the `Plan file: path: plan/....md` in the previous answer):
     - When the user uses expressions such as "previously", "just now", "previous plan", "previous plan", "adjusted on the original basis", etc., it is deemed to continue the same Plan:
       - No new files are created;
       - Use the previously recorded Plan file path as the "current Plan";
       - First read the original plan through `cat plan/XXXX.md`, and modify or incrementally update it based on this.
     - When the user clearly states "new plan", "another task", "change a requirement", "redesign a plan for YYY", it is regarded as a new plan:
       - Create new Plan files for new tasks;
       - Clearly distinguish the file paths of the old Plan and the new Plan in your answer.
   - If the user's speech is unclear, it is impossible to determine whether to continue or create a new one:
     - First ask for clarification in one sentence (for example: "Is this adjusting the previous Plan, or creating a new Plan for a completely new task?"), and then execute according to the user's choice.

2. Behavior when continuing the same Plan
   - Prioritize reading the contents of the current Plan file through the shell (for example, `cat plan/2025-12-01_17-05-30-plan.md`) to quickly review the summary of existing plans;
   - If the user wishes to adjust the plan:
     - In your answer, first give a "Summary of Changes" to explain the main modifications compared to the original Plan;
     - Then provide the updated complete plan fragment (it can replace certain phases or add new phases);
     - Update the same Plan file using append or rewrite, and explain in your answer:
       - Updated Plan file path;
       - If you use a "Change History" or "Revisions" section in your document, briefly describe your structure.

3. Behavior when creating a new Plan
   - Create a new Plan file according to "4. Plan file implementation specifications";
   - Clearly mark this as a new Plan in your answer and give the new file path;
   - If necessary, note "relationship with the old Plan" at the beginning of the new Plan file (for example, rewrite, branch plan, etc.).

Always keep the plan simple, clear, and executable, avoid over-designing for the sake of showing off skills, and adhere to the KISS / YAGNI principle.
