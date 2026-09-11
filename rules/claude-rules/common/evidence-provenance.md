# Evidence Provenance Rules

## W-21: Evidence must be provably executed, not merely cited (strict)
**Compact guidance:** Support claims with actual tool results; when remembered evidence is uncertain, inspect the original evidence or rerun the focused check.
W-03/W-16 define the verification requirement. This rule addresses uncertain provenance, not a second mandatory verification pass after every successful command.

**Out-of-session channels**:

| Channel | How to use it |
|------|------|
| Session transcript | Locate the actual command and tool_use / tool_result record rather than trusting a summary. A missing record leaves the claim unverified. |
| Filesystem | Check that the claimed artifact exists; inspect its contents or hash as appropriate. |
| Git | Use git status, git diff, and git log to establish what changed, not as a substitute for execution results. |
| Persisted single values | Exit codes and hashes can confirm a specific result when their command and input provenance are known. |

Use the smallest relevant check when output is inconsistent or a decisive claim relies on uncertain recollection. A short hash alone is not stronger than a relevant raw log; match the evidence to the claim.
Before recommending that a hook or guard be disabled because it malfunctioned, obtain concrete evidence of that malfunction. Consider both observation errors and actual environment faults without assuming either in advance.

**FIX / SKIP**: Correct or qualify unsupported claims. Skip redundant provenance artifacts when the current tool output already establishes the result. Falsifying a hypothesis can be useful progress and does not trigger a fixed-count session termination. If context becomes unreliable, recover from source artifacts or hand off the known state.
