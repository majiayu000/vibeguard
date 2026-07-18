# Task Plan — GH658

## Linked Issue

GH-658

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP658-T1` Add required closed `work_surface` and exact whole-array precedence contracts. Covers: B-001, B-002, B-003. Owner: schema worker. Dependencies: none. Writable files: `schemas/workflow-routing-decision.schema.json`. Done when: only complete surfaces and the exact six-stage array validate. Verify: `bash tests/test_workflow_contracts.sh`.
- [ ] `SP658-T2` Add the deterministic classifier priority table, ordered ladder, writing/research and chat-support verification translations, pre-payload clarification stop, and examples to the canonical routing contract. Covers: B-003, B-006, B-009, B-011. Owner: routing-contract worker. Dependencies: none. Writable files: `workflows/references/routing-contract.md`. Done when: mixed and overlapping requests have one documented outcome and unresolved classification emits no routing payload before clarification. Verify: `bash scripts/ci/validate-workflow-contracts.sh`.
- [ ] `SP658-T3` Preserve the complete routing decision beside `plan_first` handoffs, register those dependencies, keep `execute_direct` free of a handoff requirement, and require consumers to return changed intent to the canonical router instead of reclassifying. Covers: B-004, B-005, B-010. Owner: consumer worker. Dependencies: SP658-T1, SP658-T2. Writable files: `schemas/workflow-contract-consumers.json`, `workflows/references/delivery-base.md`, `workflows/plan-flow/references/execplan-integration.md`, `workflows/plan-flow/SKILL.md`, `workflows/plan-mode/SKILL.md`, `workflows/auto-optimize/SKILL.md`, `workflows/fixflow/SKILL.md`, `workflows/optflow/SKILL.md`, `agents/dispatcher.md`. Done when: cross-session execution retains both required objects, direct execution requires only routing evidence, and local reclassification is forbidden. Verify: `bash tests/test_manifest_contract.sh` and `bash tests/test_workflow_contracts.sh`.
- [ ] `SP658-T4` Update all shipped routing-summary surfaces without unrelated style-policy changes. Covers: B-006, B-007, B-009, B-011. Owner: instruction-surface worker. Dependencies: SP658-T2. Writable files: `AGENTS.md`, `templates/AGENTS.md`, `claude-md/vibeguard-rules.md`, `docs/CLAUDE.md.example`, `docs/command-schemas.md`, `docs/README_CN.md`, `.claude/commands/vibeguard/preflight.md`, `skills/vibeguard/SKILL.md`. Done when: each planned instruction surface classifies work surface before readiness and retains domain-appropriate verification. Verify: `bash scripts/ci/validate-workflow-contracts.sh` and `bash tests/test_manifest_contract.sh`.
- [ ] `SP658-T5` Add positive and negative schema/consumer regressions for all surfaces, exact precedence, clarification without payload emission, direct/planned object requirements, and persisted routing decisions. Covers: B-001, B-002, B-003, B-008, B-010, B-011. Owner: verification worker. Dependencies: SP658-T1, SP658-T2, SP658-T3, SP658-T4. Writable files: `tests/test_workflow_contracts.sh`. Done when: all valid surfaces pass and every missing, invalid, reordered, duplicated, conflicting, or lane-incomplete case fails with actionable evidence. Verify: `bash tests/test_workflow_contracts.sh`.

## Parallelization

SP658-T1 and SP658-T2 may run in parallel because their exact writable paths
are disjoint. SP658-T3 starts only after both stabilize. SP658-T4 starts after
SP658-T2. SP658-T5 starts after T1-T4 and is the sole owner of the contract
test file. The coordinator is the single full-suite verification owner; no two
lanes share a writable file.

## Verification

- `bash tests/test_workflow_contracts.sh`
- `bash scripts/ci/validate-workflow-contracts.sh`
- `bash tests/test_manifest_contract.sh`
- `bash scripts/ci/validate-doc-paths.sh`
- `bash scripts/ci/validate-doc-command-paths.sh`

## Handoff Notes

This is an intentional breaking schema change. All in-repo producers and
examples must migrate in the same implementation PR; out-of-repo producers
must add `work_surface` before upgrading.
