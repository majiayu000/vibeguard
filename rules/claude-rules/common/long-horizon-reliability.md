# Long-Horizon Reliability Rules

## W-42: Long-horizon artifact workflows must measure fidelity at checkpoints (strict)
Agent workflows that repeatedly modify and hand off the same artifact must measure semantic fidelity at fixed checkpoints. Long-horizon drift can preserve the surface shape of a document, spreadsheet, or structured file while losing meaning-bearing detail.

**Sources** (2026-05):
- Microsoft Research, "Further Notes on Our Recent Research on AI Delegation and Long-Horizon Reliability" — DELEGATE-52 reports 19-34% fidelity degradation across document, spreadsheet, and structured-file workflows over 20 delegated iterations, while Python code workflows degraded by less than 1%.
- W-18 baseline: trajectory evals must validate the path and not only the final output.
- W-12 baseline: code workflows already have an executable fidelity guard when tests and checks are preserved.
- W-20 baseline: long tasks need pinned execution surfaces; W-42 adds artifact-level drift checks inside the pinned task.

**Trigger**:
- The same artifact is modified by more than 10 agent-driven iterations.
- One iteration means an agent or delegated sub-agent modifies the artifact and passes it to the next step or agent.
- For high-risk structured artifacts such as schemas, migrations, contracts, or financial spreadsheets, the project may lower the trigger to 5 iterations.

**Required protocol (strict)**:
1. Define the baseline artifact and the meaning-bearing invariants before the delegation loop starts.
2. Measure fidelity at fixed checkpoints, with a maximum gap of 5 iterations once the workflow crosses the trigger. The default checkpoints are 5, 10, 15, and 20.
3. Use a domain-specific semantic comparator, not surface diff alone. Code can use tests, type checks, AST checks, or behavioral assertions. Documents can use key-fact extraction plus semantic comparison. Spreadsheets and structured files must check schemas, formulas, sentinel values, and domain assertions.
4. Halt before the next iteration when the comparator is missing, fails to run, or reports fidelity below the declared threshold.
5. Default thresholds are 90% fidelity for non-code artifacts and 95% for code artifacts with executable checks. A workflow may use a different threshold only if the design doc records the domain rationale.

**Mechanical checks (agent execution rules)**:
- Reject workflows that run more than 10 delegated iterations on the same artifact without a comparator and checkpoint cadence.
- Reject checkpoint plans that rely only on line count, string equality, token count, or "looks similar" review for semantic artifacts.
- Code workflows must run the selected test or check suite at every checkpoint; failure halts the delegation chain.
- If the workflow intentionally changes semantics, such as translation or summarization, the comparator must compare against the declared target meaning and invariants rather than source-text identity.

**Downgrade path**:
For workflows capped below 10 artifact-modification iterations, W-42 is vacuous if the cap is explicit in the plan or harness. For exploratory creative workflows where fidelity is not the goal, replace the numeric comparator with human review gates and declare which source invariants may be discarded.

**Anti-patterns**:
- Letting an agent chain rewrite the same document 20 times because each individual step "looked fine".
- Using final visual formatting as evidence that spreadsheet formulas or document facts survived.
- Treating code test passage as proof that embedded docs, examples, or generated files preserved their own meaning.
