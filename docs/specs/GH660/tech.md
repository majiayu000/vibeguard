# Tech Spec — remove strategic-compact skill and stale skill-name references

Linked Issue: #660
Product Spec: docs/specs/GH660/product.md
complexity: small

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Install manifest | `schemas/install-modules.json:149` | `strategic-compact` is in Claude `skills-core`, not `skills-codex-core` | Defines the only installed skill target being retired |
| Claude skill install | `scripts/setup/targets/claude-home.sh:271` | Manifest skills install as tracked symlinks | Establishes the existing-install migration shape |
| Retired link cleanup | `scripts/setup/lib.sh:524` | Tracked retired symlinks absent from the active manifest are removed; regular paths are preserved | Existing migration mechanism requires no new production code |
| Cleanup regression | `tests/setup/syntax_manifest_tests.sh:249` | Covers active, tracked-retired, untracked, and regular-directory cases | Proves B-003 without weakening user-path safety |
| W-19 guidance | `rules/claude-rules/common/workflow.md:297` | Names an external skill outside the install surface | Scoped wording replacement |

## Design

Delete the skill file, drop its Claude `skills-core` manifest entry, and
reword the two guidance surfaces that name `claude-md-split` so they describe
the action instead of the external skill. Preserve the existing tracked
symlink retirement behavior and the W-11 downgrade paragraph unchanged.

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
| B-001 skill and install metadata removed | `skills/strategic-compact/`, `schemas/install-modules.json` | `bash tests/test_manifest_contract.sh` and `if rg 'strategic-compact' schemas/install-modules.json skills; then exit 1; else test $? -eq 1; fi` |
| B-002 guidance no longer names `claude-md-split` | `workflow.md` W-19 fix, `check_doc_overload.sh` messages | `if rg 'claude-md-split' rules/claude-rules/common/workflow.md guards/universal/check_doc_overload.sh; then exit 1; else test $? -eq 1; fi` |
| B-003 tracked Claude symlink retirement preserves user-owned paths | Existing cleanup in `scripts/setup/lib.sh`; no copied Codex target | `bash tests/test_setup.sh` (sources the focused retired-link assertions) and inspection that `skills-codex-core` never contains `strategic-compact` |

## Risks

- Compatibility: a tracked Claude symlink must be removed after retirement;
  untracked or non-symlink paths must remain untouched.
- Scope: the linked implementation must not delete the unrelated W-11
  downgrade paragraph.
- Rollback: restoring the source and manifest entry recreates the tracked
  Claude symlink on the next setup run.

## Test Plan

- Manifest: `bash tests/test_manifest_contract.sh`.
- Setup cleanup: `bash tests/test_setup.sh`.
- Rule and guard wording: strict `rg` scans that distinguish exit 1 from
  scanner failure.
- Scope: `git diff origin/main...HEAD -- rules/claude-rules/common/workflow.md`
  changes only the W-19 wording block.

## Rollback

Revert the commit; the skill file and manifest entry return unchanged.
