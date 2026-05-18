# Agent Harness Audit Rules

## W-30: Harness audits must measure boundary, fidelity, and stability (strict)
Agent harness evaluation must audit the trajectory, not only final task completion. A harness can finish the requested task while violating resource boundaries, silently deviating from its declared plan, or accumulating failures as the trajectory gets longer.

**Sources** (2026-05):
- arXiv:2605.14271, "Auditing Agent Harness Safety" — evaluates agent harnesses across tasks, domains, frameworks, and frontier models, and defines boundary compliance, execution fidelity, and system stability as separate audit axes.
- W-18 baseline: output-only evaluation misses tool, step, and confidence failures.
- W-14 baseline: parallel agents need explicit ownership; W-30 extends that concern to information flow and resource boundaries.
- W-12 baseline: an eval that ignores trajectory violations is a weakened safety gate.

**Required audit axes (strict)**:
1. **Boundary compliance** — every tool call, file access, network access, credential use, and resource-consuming action must be checked against the agent's declared permission scope.
2. **Execution fidelity** — every intermediate action must match the declared plan or a logged replan event. Silent plan deviations are fidelity violations even if the final answer is correct.
3. **System stability** — violations must be reported over trajectory length so the suite can show whether failures stay isolated or accumulate as the run gets longer.
4. **Information flow** — multi-agent harnesses must log inter-agent transfers: sender, receiver, payload class, authorization basis, and redaction status when sensitive data may be present.

**Mechanical checks (agent execution rules)**:
- Reject agent harness eval reports that claim safety or readiness without all applicable audit axes.
- Per-step logs must include at least: declared scope, declared plan step or replan id, actual action, resource touched, tool result status, and violation classification.
- Multi-agent harnesses must include an information-flow log before they can claim W-14-style isolation or safe delegation.
- If violation counts grow with trajectory length, the release must treat that as a stability failure even when short runs pass.

**Downgrade path**:
For pure text generation with no tools, no resource access, and no required intermediate steps, boundary compliance and execution fidelity are vacuous if the eval suite says so explicitly. Any harness that runs more than 5 turns, delegates to another agent, or touches external resources must still report system stability or explain why no trajectory state exists.

**Anti-patterns**:
- Reporting only task success while hiding per-step tool or file access.
- Calling a multi-agent run safe because each individual agent stayed in scope, while the information passed between agents was never audited.
- Treating one short successful run as evidence that longer trajectories remain stable.
