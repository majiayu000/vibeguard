# Evidence Provenance Rules

## W-21: Evidence must be provably executed, not merely cited (strict)
**Compact guidance:** Evidence must be provably executed, not merely cited. Verify "decisive" claims through an out-of-session channel before naming a mechanism.
A long-context session can fabricate an experiment it never ran and then reason confidently from that fabricated observation. Citation discipline verifies *that* evidence is cited, not *that it happened*. Any claim labeled "decisive", "root cause locked", or "this proves it" must be verifiable outside the session's own narration.

**Trigger**:
- A claim is labeled decisive, conclusive, or root-cause-locked.
- The session is about to accuse the harness, hooks, filesystem, or environment of corruption.
- Two or more root-cause theories in the same investigation have already been falsified.
- The session has run long enough to have been compacted or summarized at least once.

**Out-of-session channels**:

| Channel | How to use it |
|------|------|
| Session transcript | Grep the on-disk session JSONL for the claimed command, file path, or output. A claim with no matching `tool_use` / `tool_result` record did not happen. |
| Filesystem | Stat or hash the file the claim depends on. A file the claim says was written must exist on disk. |
| Git | `git status`, `git diff`, and `git log` show what actually changed on disk, independent of what the session believes it changed. Git proves what changed; it never substitutes for the fresh command output W-16 requires. |
| Persisted single values | Exit codes and hashes written to a file during the run, re-read afterwards. |

**Protocol**:
1. Before labeling any finding decisive, name the out-of-session channel that can confirm it.
2. Run that check and keep its raw output.
3. Prefer single-value signals persisted to disk — exit codes, content hashes — over recalling multi-line text. Fabrication risk grows with output length, so a 1-line hash is stronger evidence than a 200-line log the session remembers reading.
4. If no out-of-session channel can confirm the claim, downgrade it from "verified" to "unverified hypothesis" and say so explicitly.

**Accusing the environment is a red flag**:
- An agent claiming the harness, hooks, tool layer, or filesystem is corrupt is itself evidence of possible model degradation. Prior probability strongly favors degraded reading and context over a broken toolchain.
- Do not act on such a claim — and never instruct a user to disable a hook, guard, or safety surface — before an out-of-session channel proves the corruption.
- High-detail rule text is raw material for plausible confabulation. Recognizing a mechanism name from the rules is not evidence that the mechanism fired.

**Session kill criterion**:
- When root-cause theories in one investigation have been falsified **2 times**, stop iterating in place. Kill the session and restart.
- Recover state from disk artifacts — files, git, checkpoints, logs — not from the degraded context.
- This is tighter than W-02's 3-failure threshold because each falsification poisons the shared evidence base the next hypothesis is built on, while W-02 counts failed fixes against a hypothesis that is still assumed sound.

**Mechanical checks (agent execution rules)**:
- A decisive claim must be accompanied by the out-of-session channel that confirms it, named explicitly.
- A request to disable a hook or guard must cite out-of-session proof of the misbehavior, not session narration.
- The second falsified root-cause theory in one investigation terminates the session; a third is already a rule violation.

**Relation to existing rules**:
- W-01 gives the debugging protocol; W-21 supplies its step 0 precondition — the observation channel must be trusted before any mechanism is named.
- W-02 counts failed fixes (3); W-21 counts falsified root-cause theories (2). They are different counters and both apply.
- W-03 requires verification; W-16 requires the verification to be fresh; W-21 requires it to be provably executed. Fresh-looking narration is not execution.
- SEC-13 documents high-context tampering surfaces. W-21 constrains how a session may *accuse* those surfaces: proof first, action second.

**Anti-patterns**:
- Narrating an experiment ("I wrote the file, read it 5 times, the hashes matched") with no corresponding tool call in the transcript.
- Escalating through increasingly exotic mechanisms — isolated filesystems, mutating file contents, output-rewriting hooks — while each prior theory is falsified.
- Framing every falsification as "progress toward the real root cause" so the back-off counters never trigger.
- Telling the user to disable a guard because it is the only remaining unexplained variable.
