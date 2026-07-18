# Tech Spec — remove strategic-compact skill and stale skill-name references

Linked Issue: #660
Product Spec: specs/GH660/product.md
complexity: trivial

## Design

Delete the skill file, drop its manifest entry, and reword the two guidance
surfaces that name `claude-md-split` so they describe the action instead of
the external skill.

<!-- specrail-planned-changes -->
```json
{
  "issue": 660,
  "complete": true,
  "paths": [
    "skills/strategic-compact/SKILL.md",
    "schemas/install-modules.json",
    "rules/claude-rules/common/workflow.md",
    "guards/universal/check_doc_overload.sh"
  ],
  "spec_refs": ["specs/GH660/product.md", "specs/GH660/tech.md", "specs/GH660/tasks.md"]
}
```

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 skill removed from tree + manifest | `skills/strategic-compact/`, `schemas/install-modules.json` | `bash tests/test_manifest_contract.sh` |
| B-002 guidance no longer names claude-md-split | `workflow.md` W-19 fix, `check_doc_overload.sh` messages | `grep -rn 'claude-md-split' rules/ guards/` returns nothing |

## Rollback

Revert the commit; the skill file and manifest entry return unchanged.
