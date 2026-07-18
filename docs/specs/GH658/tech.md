# Tech Spec — required work_surface routing classifier

## Linked Issue

GH-658

## Product Spec

`docs/specs/GH658/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Routing schema | `schemas/workflow-routing-decision.schema.json:7` | Requires only readiness and knows five precedence tokens | Executable fail-closed boundary |
| Canonical routing prose | `workflows/references/routing-contract.md:14` | Starts with risk routing after user override | Owns classifier definitions and ordering |
| Dispatcher | `agents/dispatcher.md:20` | Consumes readiness only | Must preserve the upstream surface |
| Delivery entry | `workflows/references/delivery-base.md:5` | Gates on readiness only | Must reject non-code execution starts |
| ExecPlan mirror | `workflows/plan-flow/references/execplan-integration.md:5` | Repeats the five-stage ladder | Must stay aligned with the canonical contract |
| Contract tests | `tests/test_workflow_contracts.sh:121` | Validates a routing payload without work-surface metadata | Must cover breaking positive and negative cases |

## Proposed Design

1. Add required `work_surface` and `precedence` fields. `work_surface` uses a
   closed three-value decision enum and nonempty reason. `precedence` uses one
   whole-array `const` so missing, reordered, duplicated, or extra stages fail.
   Add the new tokens to `x_markdown_tokens`.
2. Define `code_execution`, `writing_research`, and `chat_support` with an
   exhaustive priority table. Project-state mutation wins for mixed work;
   durable prose without project mutation is writing/research; no mutation or
   durable artifact is chat support. Ambiguous facts fail to clarification.
3. Require plan-mode and plan-flow to preserve the validated
   `routing_decision` alongside, not inside, the unchanged six-field handoff.
   Add that dependency to the consumer registry.
4. Require dispatcher and delivery consumers to receive both objects, reject
   missing classification, and preserve the upstream surface. Gate delivery
   workflows on `code_execution`.
5. Update each shipped routing-summary surface and example payload without
   unrelated style-policy changes.
6. Add all positive and negative schema and consumer assertions to the
   existing workflow contract suite. Do not add a fallback for old payloads.

<!-- specrail-planned-changes -->
```json
{
  "issue": 658,
  "complete": true,
  "paths": [
    "schemas/workflow-routing-decision.schema.json",
    "schemas/workflow-contract-consumers.json",
    "workflows/references/routing-contract.md",
    "workflows/references/delivery-base.md",
    "workflows/plan-flow/references/execplan-integration.md",
    "workflows/plan-flow/SKILL.md",
    "workflows/plan-mode/SKILL.md",
    "workflows/auto-optimize/SKILL.md",
    "workflows/fixflow/SKILL.md",
    "workflows/optflow/SKILL.md",
    "agents/dispatcher.md",
    "AGENTS.md",
    "templates/AGENTS.md",
    "claude-md/vibeguard-rules.md",
    "docs/CLAUDE.md.example",
    "docs/command-schemas.md",
    ".claude/commands/vibeguard/preflight.md",
    "skills/vibeguard/SKILL.md",
    "tests/test_workflow_contracts.sh"
  ],
  "spec_refs": [
    "docs/specs/GH658/product.md",
    "docs/specs/GH658/tech.md",
    "docs/specs/GH658/tasks.md"
  ]
}
```

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 missing work_surface rejected | Routing schema required list | Negative assertion in `bash tests/test_workflow_contracts.sh` |
| B-002 closed enum and nonempty reason | Routing schema object | Unknown-enum and empty-reason assertions in the same suite |
| B-003 required exact precedence array | Schema, canonical contract, examples | Missing/reordered/duplicated/extra assertions plus exact valid fixture |
| B-004 dispatcher preserves surface | Dispatcher input and rules | Workflow contract test checks required input tokens |
| B-005 delivery starts only for code execution | Delivery base and three execution skills | Contract-token validation plus focused file inspection |
| B-006 writing/research verification translation | Canonical contract and instruction surfaces | Contract-token validation plus focused file inspection |
| B-007 classify-first instruction summaries | Seven shipped instruction surfaces | `bash scripts/ci/validate-workflow-contracts.sh` |
| B-008 positive and negative contract cases | Existing workflow contract suite | `bash tests/test_workflow_contracts.sh` |
| B-009 chat support avoids code-only framing | Canonical contract and instruction surfaces | Contract-token validation plus focused file inspection |
| B-010 routing decision persists across planning handoff | Plan-mode, plan-flow, registry, dispatcher, delivery | Manifest contract plus missing-routing consumer assertions |
| B-011 deterministic mixed/overlap classification | Canonical priority table and examples | Table/example contract inspection and ambiguous-input assertion |

## Data Flow

The upstream router emits a validated `routing_decision` containing exact
precedence, work surface, and readiness. Direct consumers receive it
immediately. Planning workflows preserve that object beside the existing
six-field handoff so later or cross-session executors receive both. Consumers
reject either object when incomplete and never reconstruct the surface.

## Alternatives Considered

- Infer the surface from readiness: rejected because readiness describes
  implementation maturity, not the requested deliverable.
- Default missing surface to code execution: rejected because it preserves
  the current silent misrouting.
- Add a compatibility fallback: rejected because the issue explicitly
  requires a breaking, fail-closed schema change.
- Add `work_surface` as a seventh handoff key: rejected because the existing
  handoff schema remains stable; the complete routing decision already owns
  classification and accompanies the handoff.

## Risks

- Security: classification never expands authorization or bypasses the
  destructive-action gate.
- Compatibility: out-of-repo producers must migrate before schema adoption.
- Performance: constant-size metadata and validation.
- Maintenance: repeated prose can drift; contract-token validation and one
  canonical routing document reduce that risk.

## Test Plan

- Unit: all three valid surfaces plus missing/unknown/empty surface and
  missing/reordered/duplicated/extra precedence assertions in
  `bash tests/test_workflow_contracts.sh`.
- Consumer: plan-mode/plan-flow preservation and dispatcher/delivery rejection
  when the routing decision is missing or incomplete.
- Contract: `bash scripts/ci/validate-workflow-contracts.sh`.
- Manifest: `bash tests/test_manifest_contract.sh`.
- Manual: inspect the six-stage order and the writing/chat verification
  translations in the canonical contract and example payload.

## Rollback Plan

Revert the schema, consumer, test, and instruction-surface changes together.
Old readiness-only producers then validate again.
