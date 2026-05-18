# Vibe Coding Production Rules

## W-41: Long-term vibe coding production should expose five invariants (guideline)

Long-term production workflows that rely on vibe-coding style agent iteration should make five risk-control invariants visible before treating rapid agent changes as a normal operating mode: bounded components, queryable evidence, captured intent, minimal tooling, and low-blast-radius deployment.

**Source**: Cognitive Revolution podcast, "Vibe-Coding an Attention Firewall, w/ Steve Newman, creator of The Curve" (2026-05-17). Newman describes a long-running Cloudflare/TypeScript attention-firewall system built with Claude Code, split across roughly 15 small services, debugged through centralized logs, and deployed directly only because the system classifies or surfaces upstream data rather than mutating the source of truth.

**Five invariants**:
1. **Bounded components**: keep each agent-editable unit small enough that one session does not need to understand the whole system at once. Multiple small repositories or packages are acceptable; a monolith is acceptable only when local ownership boundaries are equally clear.
2. **Queryable evidence**: route errors, important state transitions, database mutations, and user-facing events into a place the agent can inspect. The debugging loop should be "logs, not guess".
3. **Captured intent**: preserve high-level human intent before handing work to the agent, including voice or mobile notes when that is the natural capture path. The agent may organize the prompt, but the original intent must remain recoverable.
4. **Minimal tooling**: keep the default tool surface small and add skills, plugins, daemons, or extensions only when they unlock a concrete repeated workflow.
5. **Low blast radius**: direct-to-production iteration is only reasonable when the agent does not mutate upstream ground truth, the output is reversible or replayable, and failures degrade to missing or delayed convenience rather than data loss, money movement, access changes, or publication.

**Mechanical checks (agent execution rules)**:
- When a user proposes long-term production vibe coding, surface the five invariants as a checklist and ask which missing invariants are intentional.
- If the workflow mutates ground truth, publishes externally, changes access, spends money, or deletes data, escalate to W-10 confirmation and require a human review gate before deploy.
- If there is no queryable logging or event trail, do not debug by speculation; add the evidence channel first or report that the workflow is operating without the logging invariant.
- Before adding a new tool to a vibe-coding stack, state the repeated workflow it enables and the existing tool path it replaces or complements.

**Downgrade path**:
Short-lived prototypes, throwaway explorations, and personal experiments do not need all five invariants. This rule applies when the workflow is expected to run in production for more than a brief experiment, affect other users, or become a recurring operating pattern.

**Relations**:
- W-03 and W-16 require fresh verification evidence; this rule makes logs and event trails the production evidence channel.
- W-10 governs publication, deletion, and remote deploy. The low-blast-radius invariant is not permission to skip W-10 in high-stakes workflows.
- U-32 warns against absolute rules without downgrade paths; this rule is a guideline because it describes a senior-developer risk profile, not a universal mandate.
