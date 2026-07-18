# Task Plan — GH660

## Linked Issue

GH-660

## Spec Packet

- Product: `docs/specs/GH660/product.md`
- Tech: `docs/specs/GH660/tech.md`

## Implementation Tasks

- [ ] `SP660-T1` Delete `skills/strategic-compact/SKILL.md`; remove its path and retired name from the `skills-core` entry in `schemas/install-modules.json`. Covers: B-001. Owner: implementation agent. Dependencies: none. Done when: the skill and all install metadata references are absent and the manifest contract passes. Verify: `bash tests/test_manifest_contract.sh` and `if rg 'strategic-compact' schemas/install-modules.json skills; then exit 1; else test $? -eq 1; fi`.
- [ ] `SP660-T2` Reword `rules/claude-rules/common/workflow.md` and `guards/universal/check_doc_overload.sh` so they describe the split action without naming `claude-md-split`. Covers: B-002. Owner: implementation agent. Dependencies: none. Done when: both guidance surfaces preserve their behavior but contain no retired skill name. Verify: `if rg 'claude-md-split' rules/claude-rules/common/workflow.md guards/universal/check_doc_overload.sh; then exit 1; else test $? -eq 1; fi`.

## Verification

- [ ] `SP660-T3` Run the focused manifest, rule-doc, skill-format, and reference checks after implementation. Covers: B-001, B-002. Owner: verification owner. Dependencies: SP660-T1, SP660-T2. Done when: every named command exits zero on the implementation head. Verify: `bash tests/test_manifest_contract.sh`, `bash scripts/ci/validate-rules.sh`, `bash scripts/ci/validate-generated-rule-docs.sh`, and `bash scripts/ci/validate-skill-format.sh`.

## Handoff Notes

Use the existing implementation PR #667 and preserve the original branch.
Merge remains gated by current CI, independent review, review-thread state, and
`checks/pr_gate.py`.
