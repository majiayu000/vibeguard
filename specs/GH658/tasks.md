# Task Plan — GH658

Linked Issue: #658
Specs: specs/GH658/product.md, specs/GH658/tech.md

## Implementation Tasks

- SP658-T1 — Schema: `work_surface` object, top-level `required`, precedence
  entry + `minItems` 6; update contract test payload.
  Owner: agent. Depends: none.
  Done-when: schema validates payloads with `work_surface` and rejects those
  without it.
  Verify: `bash tests/test_workflow_contracts.sh`
  Covers: B-001, B-002, B-003, B-008

- SP658-T2 — Canonical docs: routing-contract.md six-stage ladder with Work
  Surface Classifier section + writing/research worked example;
  execplan-integration.md ladder; command-schemas.md example payload.
  Owner: agent. Depends: SP658-T1.
  Done-when: ladder order and surface definitions match the schema.
  Verify: manual ladder/order comparison against schema `x_markdown_tokens`
  Covers: B-003, B-006

- SP658-T3 — Consumers: dispatcher upstream requirement + no-silent-
  conversion rule; delivery-base/fixflow/optflow/auto-optimize start
  preconditions.
  Owner: agent. Depends: SP658-T1.
  Done-when: all five consumer files gate on `code_execution`.
  Verify: `grep -l 'code_execution' workflows/references/delivery-base.md workflows/fixflow/SKILL.md workflows/optflow/SKILL.md workflows/auto-optimize/SKILL.md agents/dispatcher.md`
  Covers: B-004, B-005

- SP658-T4 — Instruction surfaces: AGENTS.md, templates/AGENTS.md,
  claude-md/vibeguard-rules.md, docs/CLAUDE.md.example, preflight command,
  vibeguard SKILL checklist.
  Owner: agent. Depends: SP658-T1.
  Done-when: each surface says classify `work_surface` before `readiness`.
  Verify: `grep -l 'work_surface' AGENTS.md templates/AGENTS.md claude-md/vibeguard-rules.md docs/CLAUDE.md.example .claude/commands/vibeguard/preflight.md skills/vibeguard/SKILL.md`
  Covers: B-007

## Verification Tasks

- SP658-V1 — `bash tests/test_workflow_contracts.sh` full run.
  Covers: B-001, B-002, B-003, B-008

## Handoff Notes

- Merge gate: human review + merge (maintainer). Breaking schema change —
  out-of-repo producers must adopt `work_surface` first (product migration
  note).

## Coverage Check

Product IDs: B-001..B-008. Task coverage union: B-001..B-008. No mismatch.
