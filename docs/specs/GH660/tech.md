# Tech Spec — remove strategic-compact skill and stale skill-name references

Linked Issue: #660
Product Spec: docs/specs/GH660/product.md
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
  "spec_refs": ["docs/specs/GH660/product.md", "docs/specs/GH660/tech.md", "docs/specs/GH660/tasks.md"]
}
```

## Product-to-Test Mapping

| Behavior invariant | Implementation area | Verification |
| --- | --- | --- |
| B-001 skill and install metadata removed | `skills/strategic-compact/`, `schemas/install-modules.json` | `bash tests/test_manifest_contract.sh` and `! rg 'strategic-compact' schemas/install-modules.json skills` |
| B-002 guidance no longer names `claude-md-split` | `workflow.md` W-19 fix, `check_doc_overload.sh` messages | `! rg 'claude-md-split' rules/claude-rules/common/workflow.md guards/universal/check_doc_overload.sh` |

## Rollback

Revert the commit; the skill file and manifest entry return unchanged.
