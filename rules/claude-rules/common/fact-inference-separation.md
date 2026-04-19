# Fact / Inference / Suggestion Separation Rules

## W-11: LLM output must separate facts, inferences, and suggestions (strict)

When an agent produces an analysis report, technical judgment, or architecture recommendation, it must label the source of confidence for each claim. Do not disguise inference as fact.

**Applies to**:
- Code review conclusions
- Architecture analysis
- Root-cause analysis
- Performance or security assessments
- Insight reports built from logs or data

**Three categories**:

### Fact
Directly verifiable information from code, logs, test output, or documentation.
- Must be traceable to a concrete file, line number, or command output.
- Cite the source as `[source: src/main.rs:42]` or `[source: cargo test output]`.

### Inference
Logical reasoning based on facts, but not directly verified.
- Must state both the evidence and the confidence level.
- Use qualifying phrases such as "based on X", "possibly because", or "the data suggests".
- Do not generalize broad conclusions from small samples.

### Suggestion
An action recommendation based on experience or best practice.
- Must state the prerequisite assumptions.
- Provide at least one alternative.
- Explain the risk and cost.

**Output format**:
```
## Facts
- [source: error.log:15] The service returned an OOM error at 03:15.
- [source: metrics] Memory grew from 2 GB to 8 GB between 03:00 and 03:15.

## Inferences
- [based on: memory curve + OOM timestamp] There may be a memory leak (confidence: medium).
- [based on: recent commit] The March 14 batch-processing change may be the trigger (confidence: low, not verified).

## Suggestions
- [assumption: it is a memory leak] Add memory profiling to `batch_process()`.
- [alternative: it may not be a leak] Check whether an abnormal input spike caused a legitimate peak.
```

**Anti-patterns**:
- Generalizing a universal conclusion from a few passing test cases.
- Using second-hand articles or blog posts as if they were factual architecture proof.
- Mixing facts and inferences without labeling them.
- Building a long reasoning chain on top of an unverified assumption.

**Confidence guide**:

| Confidence | Condition |
|------|------|
| High | Direct evidence exists (code, logs, test output) and can be independently verified |
| Medium | Indirect evidence exists and the reasoning chain is at most two steps |
| Low | Based on analogy, experience, or second-hand information, with more than two reasoning steps |

**Mechanical checks (agent execution rules)**:
- When generating an analysis report, make sure every claim is labeled as fact, inference, or suggestion.
- Every inference must include a confidence level.
- Every suggestion must include its prerequisite assumption.
- If a "fact" lacks a source, downgrade it to an inference or add the source.
