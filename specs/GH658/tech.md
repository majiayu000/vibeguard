# Tech Spec — work_surface classifier in the routing contract

Linked Issue: #658
Product Spec: specs/GH658/product.md

## Codebase Context

- `schemas/workflow-routing-decision.schema.json:7` — `required` is
  `["readiness"]`; `precedence` requires 5 entries. This is the executable
  contract consumed by `tests/test_workflow_contracts.sh:121`.
- `workflows/references/routing-contract.md:16` — canonical 5-stage
  precedence ladder; every workflow and instruction surface links here.
- `agents/dispatcher.md:20` — dispatcher consumes upstream
  `routing_decision.readiness` only; no surface classification exists.
- `workflows/references/delivery-base.md:7` — shared start preconditions for
  fixflow/optflow; keyed on `readiness` only.
- `workflows/plan-flow/references/execplan-integration.md:9` — repeats the
  precedence ladder for ExecPlan.
- Instruction surfaces repeating the L6 contract line: `AGENTS.md:11`,
  `templates/AGENTS.md:35`, `claude-md/vibeguard-rules.md:15`,
  `docs/CLAUDE.md.example:22`, `.claude/commands/vibeguard/preflight.md:17`,
  `skills/vibeguard/SKILL.md:38`, `docs/command-schemas.md:22`.

## Design

1. Schema: add `work_surface` object (`decision` enum of three surfaces +
   required `reason`), add it to top-level `required`, insert
   `work_surface_classifier` into the `precedence` items and bump `minItems`
   5 → 6. Fail-closed: no default, no compatibility branch.
2. Canonical contract doc gains a "Work Surface Classifier" stage (position
   2) defining the three surfaces, the writing_research verification
   translation, and a worked writing/research example.
3. Dispatcher: require upstream `work_surface`, add the no-silent-conversion
   rule (B-004).
4. Delivery surfaces (delivery-base, fixflow, optflow, auto-optimize) gain
   the `code_execution` start precondition (B-005).
5. Instruction surfaces update their contract summary lines to
   "classify work_surface, then choose readiness" (B-007).
6. Contract test payload gains a `work_surface` block (B-008).

<!-- specrail-planned-changes -->
```json
{
  "issue": 658,
  "complete": true,
  "paths": [
    "schemas/workflow-routing-decision.schema.json",
    "workflows/references/routing-contract.md",
    "workflows/references/delivery-base.md",
    "workflows/plan-flow/references/execplan-integration.md",
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
  "spec_refs": ["specs/GH658/product.md", "specs/GH658/tech.md", "specs/GH658/tasks.md"]
}
```

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 missing work_surface rejected | schema `required` | `bash tests/test_workflow_contracts.sh` (schema validation step) |
| B-002 three-value enum + reason | schema `work_surface` object | same schema validation; enum drives it |
| B-003 six-stage precedence, classifier second | schema `precedence` minItems 6 + routing-contract.md ladder | `bash tests/test_workflow_contracts.sh`; manual: ladder order in routing-contract.md matches schema `x_markdown_tokens` |
| B-004 dispatcher no silent conversion | `agents/dispatcher.md` rules block | manual check: rule line present; dispatcher yaml block includes work_surface |
| B-005 delivery starts need code_execution | delivery-base.md + 3 workflow SKILL.md start conditions | `grep -l 'code_execution' workflows/references/delivery-base.md workflows/{fixflow,optflow,auto-optimize}/SKILL.md` returns all four |
| B-006 writing verification translation | routing-contract.md classifier section + rules/templates wording | manual check: section text present in routing-contract.md and mirrored surfaces |
| B-007 instruction surfaces classify-first | 7 instruction files | `grep -l 'work_surface' <the seven files>` returns all |
| B-008 contract test passes | `tests/test_workflow_contracts.sh` payload | `bash tests/test_workflow_contracts.sh` exits 0 |

## Risks / Compatibility

- Intentionally breaking (see product migration note). All in-repo producers
  are updated in the same change; out-of-repo producers fail validation
  loudly rather than routing without a surface decision.
- Doc-heavy diff: risk of drift between surfaces is mitigated by B-007 grep
  verification and the schema `x_markdown_tokens` list.

## Rollback

Revert the implementation commit; the schema returns to 5-stage/`readiness`-
only and all instruction surfaces return to the previous contract line.
