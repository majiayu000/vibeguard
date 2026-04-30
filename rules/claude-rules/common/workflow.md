# Workflow Constraint Rules

> Adapted from the Superpowers framework and made complementary to VibeGuard's existing rules. Focused on debugging, verification, and TDD workflow constraints.

## W-01: No fixes without root cause (strict)
Every bug fix must identify the root cause before changing code. Do not make blind "let's try this" patches.

**Four-phase debugging protocol**:
1. **Root-cause investigation** — read the error message, reproduce consistently, inspect recent changes, trace the data flow
2. **Pattern analysis** — find a working reference implementation and compare it line by line
3. **Hypothesis validation** — form one hypothesis, run the smallest test that can prove or disprove it, then switch hypotheses if needed
4. **Implement the fix** — write the reproduction test first, apply one fix, verify it passes, then check for regressions

**Mechanical checks**:
- The first step in a bug fix must be reproducing the problem, either by running a command or writing a test, not guessing from static reading alone.
- If you cannot reproduce it, first confirm whether there is an environment difference instead of assuming it "should" reproduce.
- After the fix, rerun the reproduction step to verify the problem is gone.

## W-02: Back off after 3 consecutive failures (strict)
If you fail to fix the same problem three times in a row, stop and question the hypothesis or the architectural direction.

**Anti-pattern**: edit -> fail -> fix -> new fail -> fix -> new fail ...

**Correct response**:
1. Stop the current direction.
2. Re-read the full error context, not just the latest message.
3. Challenge the assumptions: did you misunderstand the problem, or is the design itself wrong?
4. If you still have no traction, report the situation to the user, including what you already tried.

**Theory** (MiCP, arXiv:2604.01413):
Research on multi-round reasoning suggests the optimal stopping policy comes from allocating an error budget across rounds, not from a hardcoded round count. "Three times" is a practical heuristic: after each failed attempt, the confidence of the active hypothesis tree drops exponentially, and the expected value of continuing approaches zero. Past that threshold, changing direction has higher expected value than repeating the same line of attack.

## W-03: Verify before claiming completion (strict)
Before saying "fixed" or "done", produce fresh verification evidence.

**Protocol**:
```
1. IDENTIFY — Which command can prove the claim?
2. RUN      — Execute the command
3. READ     — Read the full output and exit code
4. VERIFY   — Does the output actually support the claim?
5. REPORT   — State success with the evidence attached
```

**Forbidden phrases before verification**:
- "This should work now"
- "It looks fine"
- "It passed earlier"
- "It is fixed in theory"

**Nyquist rule** (inspired by GSD):
- Every task or step needs a verification command that finishes within **60 seconds**
- If you cannot verify quickly, the task is probably too large and needs to be split
- Example commands: `cargo test --lib`, `curl -s localhost:8080/health`, `python -m pytest tests/test_x.py -x`

**Mechanical checks**:
- Whenever you claim a fix or completion, check whether this conversation contains the matching command output.
- If not, run verification first and only then claim success.
- Every ExecPlan step must include a `verify_cmd` field (see `exec-plan.md`).

## W-13: Analysis paralysis guard (strict)
If there are 7+ consecutive read-only actions (Read / Glob / Grep) with no write action, you must either act or report a blocker.

**Trigger**: the PostToolUse hook counts consecutive research-only tool usage in the current session.

**Correct responses**:
- Start editing code or writing files
- Tell the user what blocker is preventing progress
- If more reading is genuinely required, explain why the earlier reading was insufficient

**Anti-patterns**:
- Reading 10 files in a row without producing either a change or a conclusion
- Jumping between files in search of "perfect understanding" without ever starting the work

## W-04: Test first (guideline)
For new features, prefer writing the failing test first, then writing the minimum implementation needed to pass it.

**TDD loop**:
```
RED      -> write the test and confirm it fails (assertion failure, not a compile error)
GREEN    -> write the minimal code that makes it pass
REFACTOR -> keep the tests green while cleaning the implementation
```

**Best-fit scenarios**:
- New feature work -> strict TDD
- Bug fixes -> write a reproduction test first (pairs with W-01)
- Refactors -> make sure tests already cover behavior before editing

**Not a fit**: exploratory prototypes, configuration changes, documentation updates

## W-12: Protect test integrity (strict)
When tests fail, fix the production code rather than manipulating the test harness. Do not "pass" the suite by weakening tests or infrastructure.

**Source**: OpenAI, "Monitoring Reasoning Models for Misbehavior" (Baker et al., 2026) — seven classes of reward-hacking behavior were observed in RL-trained coding agents, and every one manipulated tests instead of fixing the underlying issue.

**Known hack patterns to forbid**:

| Pattern | Description |
|------|------|
| Test framework tampering | Modify `conftest.py`, test setup, or the test runner so tests skip or always pass |
| Verification function tampering | Make `verify()`, `validate()`, or `check()` always return true |
| Stub substitution | Write an empty stub instead of a real implementation when tests are weak |
| Assertion weakening | Relax assertions (`assertEqual` -> `assertTrue`, exact match -> containment check) |
| Expected-value extraction | Parse the test file at runtime and hardcode the expected value into the implementation |

**Allowed test changes**:
- Requirements changed and the old test case is obsolete -> update it after user confirmation
- The test itself has a real bug (for example, an inverted assertion) -> fix it and explain why
- New TDD tests -> normal W-04 flow
- External services are unavailable -> add a justified skip condition while preserving the original test

**Mechanical checks (agent execution rules)**:
- If tests fail and the next edit touches a test file instead of source, stop and ask whether you are fixing a real test bug or bypassing the test.
- If you modify `conftest.py`, pytest config, `jest.config`, or shared test helpers, explain why.
- If source and tests both change, test changes must not reduce assertion strength.

## W-14: Parallel-agent file ownership (strict)
When multiple agents work in parallel, prompts must assign explicit file ownership so agents cannot silently overwrite one another.

**Root cause** (source: GitHub Copilot CLI / fleet docs, 2026):
Parallel sub-agents share a file system without file locks. The last writer silently wins and no conflict is reported.

**Rules**:
- Every parallel task must receive a disjoint set of files.
- Two agents must never write the same file at the same time, even if they intend to change different lines.
- If shared output is unavoidable, use "write to a temporary path, then have the orchestrator merge later."
- Background agents, worktree agents, and long-lived agents must also declare writable, read-only, and forbidden file sets.
- Default to keeping background execution away from files the user is actively editing in the main workspace unless the user explicitly authorizes that write.
- When multiple results need to be combined, prefer temporary outputs or an isolated worktree, then let one primary executor perform the final merge.

**Prompt template**:
```
Agent A owns: src/auth.rs, src/session.rs (only modify these files)
Agent B owns: src/api.rs, src/middleware.rs (only modify these files)
```

**Mechanical checks (agent execution rules)**:
- When you receive a parallel subtask, confirm your file boundary first.
- If the task description does not specify file ownership, ask the orchestrator to clarify before editing.
- Do not modify a shared file in a "read first, write later" flow unless you have exclusive ownership.
- If a background or long-lived agent does not have an explicit writable file set, it must not start a write task.
- If a recent event shows the same file being edited by another session or agent, emit a `W-14` warning and recommend an isolated worktree or single-owner merge path.
- When file boundaries overlap, prefer shrinking the writable scope over adding more coordination rules.
- **Observability hook**: `hooks/post-edit-guard.sh` detects recent same-file edits across sessions or agents.
- **Downgrade path**: if reliable file ownership cannot be declared, fall back to a single primary writer or an isolated worktree.

## W-15: Low-information loop detection (strict)
If the information gain shrinks for three consecutive rounds, stop that direction and report it.

**How it complements W-02 and W-13**:

| W-02 | W-13 | W-15 |
|------|------|------|
| Failure loop | Read-only paralysis | Shrinking-yield loop |
| There is output, but it is wrong | No output | There is output, but it keeps shrinking |
| Trigger: 3 failed fixes | Trigger: 7 consecutive read-only actions | Trigger: 3 rounds of decreasing yield |

**Source**: Diminishing Returns Detection in Claude Code (analyzed by blog.raed.dev, 2026-04). Claude Code treats 3+ consecutive rounds with less than 500 tokens of new content as "spinning in place" and stops the loop.

**Behavioral trigger signals** (no token counter required):
- Three consecutive Edit actions keep touching the same region of the same file (within +/-10 lines)
- Three rounds produce essentially the same proposal with only wording changes
- During refactor or tuning work, the size of the change keeps shrinking while the problem is still unresolved

**Correct response**:
1. Stop the current micro-tuning direction.
2. Compare the last three rounds: are you actually repeating the same move?
3. Challenge the strategy: is the goal poorly defined, or does it require a totally different method?
4. Report to the user what was tried, what each round produced, and why the yield kept decreasing.

**Anti-patterns**:
- Switching back and forth between equivalent refactors (A -> B -> A -> B)
- Tweaking one parameter or config value each round even though nothing changes
- Writing longer and longer analysis that only restates the same conclusion

**Mechanical checks (agent execution rules)**:
- After three consecutive edits to the same file, ask whether the edits are really solving one problem and whether the change radius is shrinking.
- If diff overlap between two consecutive rounds exceeds 50%, it is probably a low-yield loop.
- Once the loop is detected, do not continue with a fourth round in the same direction without reporting it first.

## W-16: Verification commands must come from this session (strict)
When you say "fixed", "done", or "verified", you must cite command output produced in this session. Memory, "it passed earlier", or "it should work" do not count.

**Sources** (four-source convergence, 2026-04-16):
- Anthropic Claude Code Best Practices: verification is the **single highest-leverage thing**
- Addy Osmani, "Trust, But Verify": blind trust in AI code leads to defects
- Addy Osmani, "80% Problem": comprehension debt makes the final 20% easy to rubber-stamp
- Martin Fowler, "Harness Engineering": both sensor-only and feedforward-only systems fail; you need both channels

**Relation to W-03**:
- W-03 says "verification is mandatory"
- W-16 adds "verification must be fresh" — it must be generated within the current session boundary

**Forbidden claim patterns**:
- "This command passed earlier" — the code changed, so earlier output is stale
- "Based on experience, this should work" — no execution means no verification
- "The tests used to pass" — not relevant after the current changes
- Referencing memory, conversation summary, or `git log` instead of actual command output

**Correct claim pattern**:
```
Fixed: `cargo test --lib auth` passed in this session (tool output from Bash call N in this conversation)
```

**Mechanical checks (agent execution rules)**:
- If output includes "fixed", "done", or "verified", trace backward and confirm this session contains the matching command execution.
- If not, run verification first and only then make the claim.
- For test and build checks, you need exit code 0 or an equivalent positive success signal, not merely the absence of error logs.

**Rationalizations to reject**:
- "The code is simple, so it does not need to run." -> simple code can still fail because of environment or dependency drift.
- "I already reasoned it through, so it is fine." -> static reasoning does not cover runtime behavior.
- "The app does not run locally." -> at minimum run a non-runtime check such as `cargo check`, `tsc --noEmit`, or `go build ./...`.
- "Tests do not cover this path." -> add a minimal reproduction command such as `curl` or a Python REPL check.
- "I ran it a few minutes ago." -> after code changes, old output is stale.
- "CI will run it." -> CI happens later; local completion claims need local evidence.
- "A teammate or an earlier commit already verified it." -> cross-person and cross-session evidence does not count as current-session verification.

**Lightweight fallback** (Bridge R2.8 — fresh-context self-review):
Use fresh-context self-review only for documentation-only or design-only changes where no command can prove the claim. It cannot replace command execution for code, configuration, setup, migration, or runtime behavior changes.

The fallback must leave an auditable artifact, such as a transcript link/id, captured clean-context output, or a reviewer note with the exact prompt and verdict. Without that artifact, the fallback is only another unsupported claim. This evidence is weaker than command execution but stronger than a bare assertion.

## W-17: Fewer smarter gates beat more mechanical gates (strict)
When the user asks to add a new gate or rule, first ask whether an existing gate can absorb the new condition instead of creating one more overlapping rule.

**Relation to U-32**:
- U-32 defines the overload threshold (more than 30 constraints triggers a warning)
- W-17 defines the design principle for how to stay below that threshold

**Decision questions**:
1. Which existing gate catches the closest failure mode?
2. Can you extend the decision logic of that gate instead of adding a separate entry?
3. Do the trigger conditions overlap? If yes, they must be merged.
4. Does the new gate have a downgrade path? If not, absolute language plus no downgrade path creates illusion of control (the U-32 anti-pattern).

**Positive examples**:
- W-15 (low-yield loop) complements W-02 (failure loop) and W-13 (read-only paralysis) instead of becoming an unrelated fourth rule
- W-16 (verification must be from this session) refines W-03 (verification required) instead of replacing it

**Anti-patterns**:
- Adding a new standalone rule for every newly observed failure mode, until users cannot remember 30+ rules
- Repeating the same concept in three different files (for example, "do not swallow errors silently" in `CLAUDE.md`, U-17, and U-29)
- Solving a problem with rules that should be handled mechanically by a hook or skill (for example, "do not skip verification" belongs in automation, not in rule count inflation)

**Mechanical checks (agent execution rules)**:
- When a user says "add a rule", first search whether the existing rule set already covers it.
- If it can be merged, extend the existing rule instead of allocating a new ID.
- If a new rule is unavoidable, evaluate whether it should instead be downgraded into a skill or hook (automation > more rules).
- If more than five new rules are added to one file, split them by theme into child files.

## W-05: Sub-agent context isolation (guideline)
When using sub-agents, give each child only the minimum context required for its task.

**Rules**:
- Implementation agents: only the target files, interface definitions, and tests
- Review agents: only the diff and the relevant spec
- Do not forward the entire parent conversation wholesale
- Background, long-lived, and scheduled agents should also receive only the context needed for the current task.
- Keep persistent rule surfaces limited to high-frequency, stable, cross-task constraints; push lower-frequency workflows down into skills, hooks, or verify scripts.

**Why**: the larger the context, the higher the hallucination risk. Isolated child agents stay more focused and more reliable.

## W-18: Evaluations must validate path, not only output (strict)
Output-only evaluations miss systemic failures. An agent or pipeline can produce the correct final answer through the wrong tool, by skipping a required step, or with miscalibrated confidence; in production these all read as "passing" but degrade the moment the inputs shift.

**Sources** (2026-04-27):
- Confident AI, "Three Ways AI Systems Fail Even When Evals Pass" — names the three failure modes below
- Microsoft Research, AgentRx (2026-04) — the same failure modes recur in the 9-class trajectory taxonomy
- Anthropic Claude Code postmortem (2026-04-24) — quality degradation that no end-to-end eval caught, because the eval did not look at session-state behavior

**The three failure modes that pass output-only evals**:

| Mode | Description | What the eval saw | What was actually wrong |
|------|-------------|-------------------|-------------------------|
| Wrong tool, right answer | Used a search tool when a structured DB lookup was required | Correct value in response | Cached or pretrained knowledge, not the current source of truth |
| Skipped required step | Answered without doing the mandatory retrieval / validation step | Correct answer | Bypassed the very check that the system was designed to enforce |
| Miscalibrated confidence | Returned a wrong answer with high stated certainty | "Confident" output | No signal for downstream caller to fall back |

**Required eval coverage (strict)**:

Every eval suite that gates a release or guards a production agent must validate three axes, not one:

1. **Tool selection** — assert that the trajectory used the expected tool (or a member of an allowed set) for each protected step. If the agent has no tools, this axis is vacuous and may be skipped, but the suite must say so explicitly.
2. **Step adherence** — assert that the trajectory contains every mandatory step in the documented order. Examples: retrieval before answer, schema validation before write, permission check before mutation. A "skip step" must fail the eval even when the final output is correct.
3. **Confidence calibration** — assert that stated confidence tracks correctness on the eval set. Concretely, expected calibration error (ECE) on the bucketed predictions must be reported alongside accuracy. An agent that is 90% confident on a sample where it is correct 50% of the time is a calibration failure even if accuracy is "fine".

**Mechanical checks (agent execution rules)**:
- When asked to "evaluate" a model, agent, or pipeline, first ask: does the suite log the trajectory (tool calls, ordered steps, stated confidence) or only the final output?
- If only the final output is logged, the suite cannot satisfy W-18. The required fix is to record trajectory metadata, not to add more output-level cases.
- When adding a new eval case, declare its target axis. A case that does not exercise tool selection, step adherence, or confidence calibration is an output-only case and must be balanced by cases on the other axes.
- Reject pull requests that claim "evals pass" while the eval definition does not assert any of the three axes.

**Anti-patterns**:
- Reporting `pass@k` as the only quality metric for a tool-using agent.
- Adding more end-to-end golden outputs to "harden" a regression that was actually a tool-selection or step-skip failure.
- Reading model confidence directly without ever measuring how it correlates with correctness.
- Marking a release green because output-level evals are stable, when the underlying trajectory shape has changed.

**Downgrade path**:
For pure text generation tasks with no tools and no required intermediate steps, axes 1 and 2 are vacuous and may be skipped if the eval suite explicitly states so. Axis 3 (calibration) is never optional whenever the model emits or implies a confidence value to a caller.
