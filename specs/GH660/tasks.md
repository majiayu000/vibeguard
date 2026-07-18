# Task Plan — GH660

Linked Issue: #660
Specs: specs/GH660/product.md, specs/GH660/tech.md

- SP660-T1 — Delete `skills/strategic-compact/SKILL.md`; remove its
  `skills-core` path from `schemas/install-modules.json`.
  Owner: agent. Depends: none.
  Done-when: manifest contract test passes with the entry gone.
  Verify: `bash tests/test_manifest_contract.sh`
  Covers: B-001

- SP660-T2 — Reword `rules/claude-rules/common/workflow.md` (W-19 fix) and
  `guards/universal/check_doc_overload.sh` messages to drop the
  `claude-md-split` skill name.
  Owner: agent. Depends: none.
  Done-when: grep for the skill name over rules/ and guards/ returns nothing.
  Verify: `grep -rn 'claude-md-split' rules/ guards/ || echo clean`
  Covers: B-002

Coverage: B-001, B-002 both mapped. Merge gate: human review + merge.
