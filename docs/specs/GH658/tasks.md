# Task Plan — GH658

## Linked Issue

GH-658

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP658-T1` Add required closed `work_surface` and exact whole-array precedence contracts. Covers: B-001, B-002, B-003. Owner: implementation agent. Done when: only complete surfaces and the exact six-stage array validate. Verify: `bash tests/test_workflow_contracts.sh`.
- [ ] `SP658-T2` Add the deterministic classifier priority table, ordered ladder, writing/research and chat-support verification translations, and examples to canonical routing documents. Covers: B-003, B-006, B-009, B-011. Owner: implementation agent. Done when: mixed and overlapping requests have one documented outcome and ambiguity fails to clarification. Verify: `bash scripts/ci/validate-workflow-contracts.sh`.
- [ ] `SP658-T3` Preserve the complete routing decision beside plan-mode/plan-flow handoffs, register those dependencies, and require dispatcher/delivery consumers to receive it without reclassification. Covers: B-004, B-005, B-010. Owner: implementation agent. Done when: cross-session execution retains work surface and missing routing evidence fails loudly. Verify: `bash tests/test_manifest_contract.sh` and `bash tests/test_workflow_contracts.sh`.
- [ ] `SP658-T4` Update all shipped routing-summary surfaces without unrelated style-policy changes. Covers: B-006, B-007, B-009, B-011. Owner: implementation agent. Done when: each planned instruction surface classifies work surface before readiness and retains domain-appropriate verification. Verify: `bash scripts/ci/validate-workflow-contracts.sh` and `bash tests/test_manifest_contract.sh`.
- [ ] `SP658-T5` Add positive and negative schema/consumer regressions for all surfaces, exact precedence, and persisted routing decisions. Covers: B-001, B-002, B-003, B-008, B-010, B-011. Owner: implementation agent. Done when: all valid surfaces pass and every missing, invalid, reordered, duplicated, or conflicting case fails with actionable evidence. Verify: `bash tests/test_workflow_contracts.sh`.

## Parallelization

T1 owns the routing schema. T2 owns canonical routing docs. T3 owns planners,
the consumer registry, dispatcher, and delivery workflows. T4 owns instruction
summaries. T5 owns contract tests. These paths are disjoint, but one
integration owner must reconcile contract wording and run the full
verification set.

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
