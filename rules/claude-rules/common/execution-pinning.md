# Execution Pinning Rules

## W-20: Long tasks must pin runtime, tools, and rules (strict)
Long-running agent tasks must freeze the execution surface at the start of the task so a mid-flight runtime, tool, or rule change cannot silently alter the result.

**Trigger**:
- The task crosses 3 or more agent steps.
- The task is expected to run for 10 minutes or longer.
- The task enters `/vibeguard:interview` or `/vibeguard:exec-plan`.
- The task delegates work to child agents, background sessions, or scheduled automation.

**Required pinned surfaces**:

| Surface | Required evidence |
|------|------|
| Runtime | agent CLI version, selected model ID, and key SDK/runtime versions relevant to the task |
| Tools | complete tool / MCP server / skill inventory, including a stable description hash for every entry |
| Rules | hash of the loaded VibeGuard rule set for the task |

**Protocol**:
1. Before execution starts, write or generate a tool inventory file that lists every tool, MCP entry, or skill available to the task.
2. Run `bash guards/universal/check_runtime_drift.sh snapshot --snapshot <file> --tool-inventory <file>`.
3. Store the snapshot path in the SPEC, ExecPlan, or shared planning handoff.
4. Before resuming a long task in a later session, run `bash guards/universal/check_runtime_drift.sh check --snapshot <file> --tool-inventory <file>`.
5. If drift is detected, stop and show the changed surface before continuing.

**Mechanical checks (agent execution rules)**:
- `interview` and `exec-plan` flows must capture the runtime pinning snapshot path before they hand off to execution.
- A task cannot claim deterministic replay or stable review evidence unless the runtime, tools, and rules hashes match the original snapshot.
- Tool inventory entries must include description hashes; a name-only tool list is not enough because MCP and skill descriptions are instruction-bearing surfaces.
- Runtime pinning complements SEC-12 and SEC-13: SEC-12 covers MCP description drift after installation, SEC-13 covers high-context file tampering, and W-20 covers task-local drift during execution.

**Downgrade path**:
If the user explicitly accepts drift, record the decision in a project-level security or decision log before continuing. The record must include the old snapshot, current check output, accepted surface, reason, approver, and timestamp.

Use:

```bash
bash guards/universal/check_runtime_drift.sh accept \
  --snapshot .vibeguard/runtime-pinning.snapshot \
  --tool-inventory .vibeguard/tool-inventory.txt \
  --decision-log SECURITY.md \
  --reason "User accepted Codex CLI upgrade during this task"
```

**Anti-patterns**:
- Continuing a cross-session ExecPlan after the agent CLI auto-updated without showing the user.
- Treating a tool name list as stable while tool descriptions changed.
- Re-running verification after rule files changed and presenting it as equivalent to the original task.
- Recording "user accepted drift" only in chat, with no durable project log.
