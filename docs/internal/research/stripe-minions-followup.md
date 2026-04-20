#StripeMinions Part 2 — To be followed

> Original text: https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents

## The second article should focus on

- [ ] **Specific implementation of deterministic orchestration** — How do the agent loop and lint/git/test alternate, and how do the statuses pass?
- [ ] **MCP Toolshed Architecture** — How to organize 400+ tools and select subsets according to tasks
- [ ] **Heuristic strategy for selective CI** — How to select relevant runs among 3 million tests
- [ ] **Prompt / Rule file design** — the specific format of conditional application rules
- [ ] **Failure handling and 2-round upper limit** — Fix the judgment logic of the loop

## Directions that can be brought back to VibeGuard

| Stripe approach | VibeGuard correspondence | Gap |
|-------------|---------------|------|
| Deterministic step alternating agent loop | Hooks are already in prototype | Lack of orchestration layer, hooks are passively triggered |
| Local lint <5s feedback | PostToolUse hooks | Expandable coverage |
| iteration cap 2 rounds | cross-review 3 rounds cap | aligned |
| Environment preheating 10s | preflight manual trigger | can be automated |
| Selective testing | None | Need to add |
