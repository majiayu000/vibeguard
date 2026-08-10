# Delegation Contract

Delegation is opt-in, not the default execution model.

Use another agent only when the user explicitly requests it or a major task contains genuinely independent work. Keep exactly one writable session per repository. Isolated worktrees protect unrelated local state; they do not authorize a second writable session.

Before delegating, state the bounded outcome, writable paths, read-only context, required evidence, and who integrates the result. Shared high-context files stay with one writer.

Do not create coordinator, implementer, reviewer, and merge-reviewer lanes for an ordinary task. The primary session owns implementation, verification, and handoff unless independence materially improves safety.

Stop delegation when:

- ownership overlaps;
- the task is small enough to finish directly;
- a worker needs new authority;
- integration would cost more than the independent work;
- delegation would create a second writable session for the repository.
