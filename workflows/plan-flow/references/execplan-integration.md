# ExecPlan Integration

ExecPlan is an explicit recovery document for genuinely long architecture or migration work. It is not required for ordinary implementation.

## Selection

| Tool | Use |
|---|---|
| `plan-mode` | User explicitly asks for a one-session plan |
| `plan-flow` | User requests durable convergence analysis |
| ExecPlan | Major work must resume across sessions |

Small bugs, docs, tests, and mechanical changes execute directly and do not create an ExecPlan.

## Content

An ExecPlan records:

- target outcome and non-goals;
- current repository and remote evidence;
- ordered milestones;
- verification commands;
- decision log;
- first pending action;
- true stop conditions.

It does not require a routing object, fixed handoff fields, or delegation lanes.
Because an ExecPlan is cross-session work, it must record the W-20 snapshot for
the runtime, tools, and loaded rules. Ordinary one-session tasks do not create
this snapshot. During `init`, resolve the execution source from
`${VIBEGUARD_DIR:-${HOME}/.vibeguard/installed}`, write the tool inventory, and
run its `guards/universal/check_runtime_drift.sh` with an explicit `--rules-dir`
pointing to the same source's `rules/claude-rules`. Store both resulting paths
in the ExecPlan Context section. Resume runs the same installed guard in
`check` mode with the same explicit rules directory and stops on drift.

## Resume

When a new session resumes:

1. Read the ExecPlan and live `git status`.
2. Refresh remote facts that may have changed.
3. Check the recorded W-20 snapshot and show any runtime, tool, or rule drift.
4. Confirm the target is still authorized and relevant.
5. Continue from the first pending milestone.
6. Run focused verification after each change.
7. Stop and ask only when a new material choice or authority boundary appears.

Prefer a new short session per issue over keeping one session alive through repeated compaction.

## Delegation

Delegation is optional and user-directed. If selected, follow [`workflows/references/delegation-contract.md`](../../references/delegation-contract.md) and keep one writable session per repository.
