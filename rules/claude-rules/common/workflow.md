# Workflow Constraint Rules

> Adapted from the Superpowers framework and made complementary to VibeGuard's existing rules. Focused on debugging, verification, and TDD workflow constraints.

## W-01: No fixes without root cause (strict)
**Compact guidance:** No fixes without root cause: reproduce first, then form one hypothesis, then fix.
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
**Compact guidance:** After 3 consecutive failed fixes on the same problem, stop and challenge the hypothesis or architecture.
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
**Compact guidance:** Verify before claiming completion: produce fresh command output proving the claim.
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
**Compact guidance:** Protect test integrity: fix production code, never weaken assertions or tamper with test infrastructure.
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
- If source and tests both change, test changes must not reduce assertion strength; run `bash guards/universal/check_test_weakening.sh --base origin/main --head HEAD` during PR review when a diff is available.

## W-14: Parallel-agent file ownership (strict)
**Compact guidance:** Parallel agents must have explicit, disjoint file ownership; no shared writable file.
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

**Implementation contract** (`hooks/_lib/post_edit_history.sh::vg_post_edit_detect_w15_loop`):
- Same-file consecutiveness alone is **not** sufficient — the detector reads each prior edit's `len(new_string) - len(old_string)` from the event log and only fires when:
  1. three or more consecutive edits target the same file, **and**
  2. the absolute change radius is non-increasing across those three rounds (`|Δ_oldest| ≥ |Δ_mid| ≥ |Δ_latest|`), **and**
  3. the latest absolute delta is in the micro-tuning band (`|Δ_latest| < 300` chars).
- This excludes natural long-form writing (markdown sections, RFC drafts) where each edit adds substantial new content (`|Δ| ≥ 300`), which previously produced 100% false positives.

**Downgrade path** (U-32 compliance):
- `VIBEGUARD_SUPPRESS_W15=1` skips the detector entirely. Use it when intentionally drafting long documents, checklist files, or any flow where same-file consecutiveness is expected.
- `VIBEGUARD_W15_SKIP_DOCS=1` (default on) skips documentation, notes, changelog, and TODO paths (`*.md`, `*.markdown`, `*.rst`, `*.txt`, `*.adoc`, `notes/*`, `*/notes/*`, `docs/daily/*`, `*/docs/daily/*`, `CHANGELOG*`, `*/CHANGELOG*`, `TODO*`, `*/TODO*`, `HISTORY*`, `*/HISTORY*`). Empirically the largest FP class — daily-log append sequences of ~25-30 chars per round stably match the micro-tuning band. Set `VIBEGUARD_W15_SKIP_DOCS=0` to opt back into detection on doc paths.
- For one-shot suppression in a single edit, the size-cap (300 chars) already prevents large content additions from triggering.

## W-16: Verification commands must come from this session (strict)
**Compact guidance:** Verification commands must come from this session. "Earlier passed" / "should work" do not count.
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

## W-19: AGENTS.md / CLAUDE.md sustainable size and pairing (strict)
Agent-instruction documents (`CLAUDE.md`, `AGENTS.md`) lose effectiveness when they grow past sustainable size, accumulate unpaired prohibitions, or inline the full text of canonical vibeguard rules. Long instruction files trigger overexploration (agents read more surrounding docs and produce worse output) and warning cascades (agents over-validate against rules irrelevant to the current task).

**Sources** (four-source convergence, 2026-04 to 2026-05):
- Augment Code, "A good AGENTS.md is a model upgrade. A bad one is worse than no docs at all." (AuggieBench measured 10-15% cross-metric drop on bloated docs).
- Anthropic Claude Code Best Practices: a bloated `CLAUDE.md` causes Claude to ignore the instructions that actually matter.
- Complement to U-32 (rule overload): U-32 sets the threshold (>30 rules per file), W-19 enforces it on the specific class of agent-instruction docs.
- Alex Kim, "You've been doing harness engineering all along": independently re-derives W-19's shape from production practice by keeping root docs under roughly 150-200 lines, splitting detailed procedures into skills/reference files, encoding rules as checks, and requiring evidence instead of prose-only claims.

**Detection thresholds**:

| Signal | Warn | Fail (strict) |
|---|---|---|
| Lines outside vibeguard auto-gen region | > 200 | > 800 |
| Chinese prohibition keywords (counted by the guard) | > 30 (warn only) | — |
| Inline mentions of any single canonical rule ID (U-17, U-26..U-32, W-01..W-17) | ≥ 3 (likely redefining canonical text) | — |

The vibeguard auto-gen region (between `<!-- vibeguard-start -->` and `<!-- vibeguard-end -->`) is excluded from line counting because it is owned by `setup.sh`.

**Fix**:
- Split into a `~150-line` index `CLAUDE.md` plus `.claude/references/` topical files, preserving routing links and path-scoped ownership.
- Replace inline canonical rule text with a single-line reference such as `see vibeguard U-29 for the canonical text`.
- For each prohibition phrase (English `Don't ...` / `NO X` or Chinese equivalents), pair it with a concrete `GOOD:` example or move the warning to a reference file.

**Mechanical checks (agent execution rules)**:
- Run `bash guards/universal/check_doc_overload.sh [target_dir]` to detect violations.
- Add `--strict` to make fail-level violations exit non-zero. Warning-only signals still report but do not block.
- The auto-gen marker region is ignored by the guard.
- Nested `AGENTS.md` files are scanned recursively, excluding generated dependency/build directories.

**Anti-patterns**:
- Repeating U-29 / U-30 / U-31 full text in `CLAUDE.md` after vibeguard already loads them.
- Adding 30+ prohibitions without paired `do` examples, then expecting the agent to remember which apply.
- Embedding the full architecture diagram, directory tree, and shared infrastructure tables directly in `CLAUDE.md` instead of in a referenced architecture doc.

## W-37: Agent learning must draw from successful and failed trajectories (strict)
An agent memory or experience layer that feeds future inference must learn from both successful and failed trajectories. Success-only memory preserves happy paths but erases the decision boundaries that caused prior failures.

**Sources** (2026-05):
- Google Research, "ReasoningBank: Enabling agents to learn from experience" — describes a retrieval, extraction, and consolidation loop that distills insights from both successful and failed trajectories.
- ReasoningBank paper and public implementation — failed trajectories are converted into preventative lessons and strategic guardrails before future retrieval.
- W-18 baseline: trajectory quality matters, not only final output.
- W-12 baseline: failed test trajectories are evidence, not noise.
- U-26 baseline: if memory is a declared component, it must be wired into the retrieval path.

**Rules**:
1. Persistent memory or experience stores must record both successful and failed trajectories with explicit outcome flags.
2. Failed trajectories must be extracted into named preventative lessons or strategic guardrails before they are pruned.
3. Retrieval for a similar task must surface both success patterns and relevant failure lessons before the agent commits to a plan.
4. Memory items must include enough trajectory metadata to diagnose reuse: tool calls, key decision points, outcome, and root cause when known.

**Mechanical checks (agent execution rules)**:
- Reject agent memory schemas that have no outcome or failure flag.
- Reject retrieval designs that query only success exemplars when failure lessons exist for the same task class.
- Reject pruning or retention policies that delete failed trajectories before extraction.
- Report W-37 when a design claims "learning from experience" but stores only wins, final answers, or hand-picked exemplars.

**Downgrade path**:
For stateless single-turn agents with no persistent memory or experience retrieval, W-37 is vacuous. The design must state that the system is stateless; otherwise absence of failure memory is a gap, not a downgrade.

**Anti-patterns**:
- Keeping only "golden" traces because failed runs look messy.
- Deleting failure logs immediately after fixing a bug, before extracting the decision boundary that caused it.
- Treating failed tests, blocked tool calls, or rejected plans as disposable noise instead of learning material.

## W-38: Tool-need recognition and tool-call execution are separate metrics (strict)
Tool-use evals must distinguish whether an agent recognized that a tool was needed from whether it actually called the tool. Collapsing both into one "tool-use accuracy" number hides the knowing-doing gap and leads to the wrong remediation.

**Sources** (2026-05):
- arXiv:2605.14038, "Model-Adaptive Tool Necessity Reveals the Knowing-Doing Gap in LLM Tool Use" — reports cognition-action mismatch rates of 26.5-54.0% on arithmetic tasks and 30.8-41.8% on factual QA tasks.
- The same paper finds late-layer directions for tool-need recognition and tool-call execution are nearly orthogonal, which means the failure can sit in the transition from recognition to action rather than in task understanding alone.
- W-18 baseline: trajectory evals must validate tool selection, not only final output.
- W-01 baseline: the first fix must distinguish the root cause, not patch every "tool was not used" symptom the same way.

**Required eval coverage (strict)**:
1. Tool-using agent evals must report **tool-need recognition** separately from **tool-call execution**.
2. Tool-need recognition may be measured from agent-derived evidence: explicit reasoning traces, tool-intent annotations, a classifier over the agent trajectory, or a review judge. Task labels alone describe necessity, not recognition. Ordinary CI does not need hidden-state probes.
3. Tool-call execution must be measured from actual trace evidence: emitted tool calls, structured action records, or audited MCP / CLI events.
4. A mismatch where recognition is correct but execution is missing must be reported as an action-layer failure, not folded into generic tool-use accuracy.

**Mechanical checks (agent execution rules)**:
- Flag eval reports that publish only one "tool-use accuracy" number for a tool-using agent.
- When debugging "the agent did not use the tool", first ask whether it recognized the tool need. If yes, target the action layer: forced invocation, retry policy, structured action format, or lower-temperature tool-decision step. If no, target the cognition layer: context, examples, retrieval, or prompt clarity.
- If recognition-correct / execution-missing mismatches exceed 20% on the eval set, remediation must include an action-layer change before adding more cognition examples.
- Report W-38 when a PR claims to fix tool use by adding examples but provides no evidence that recognition was the failing sub-axis.

**Downgrade path**:
For agents with no tools, W-38 is vacuous. For agents with exactly one mandatory tool and no choice about whether to use it, only the execution metric applies; recognition is trivially satisfied if the task class itself requires that tool.

**Anti-patterns**:
- Treating "the tool was not called" as a prompt clarity bug without checking whether the agent knew the tool was needed.
- Averaging correct recognition and missed execution into one score, then calling the eval stable.
- Adding more few-shot examples when the trace already shows correct tool intent but no emitted action.
