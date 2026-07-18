# Product Spec — remove strategic-compact skill and stale skill-name references

Linked Issue: #660
complexity: trivial

## Goals

Retire `skills/strategic-compact/` and stop pointing users at the external
`claude-md-split` skill by name from repo guidance (it is not part of this
repo's install surface).

## Non-Goals

Removing or changing any other skill; changing W-19 thresholds or the
doc-overload guard's detection logic (message wording only).

## Behavior Invariants

- B-001: `skills/strategic-compact/` no longer exists and is absent from the
  `skills-core` module paths in `schemas/install-modules.json`; the install
  manifest contract test still passes.
- B-002: Repo guidance (`rules/claude-rules/common/workflow.md` W-19 fix
  section, `guards/universal/check_doc_overload.sh` messages) describes the
  split action ("keep a short index and move topic detail into
  `.claude/references/`") without naming the `claude-md-split` skill.

## Boundary Checklist

Compatibility: covered by B-001 — installs referencing the removed path
would fail the manifest contract test, which is the fail-loud surface.
Other categories N/A — doc/manifest removal with no runtime behavior.

## Acceptance

`bash tests/test_manifest_contract.sh` passes; `grep -rn 'strategic-compact\|claude-md-split' --include='*.md' --include='*.sh' rules/ guards/ schemas/ skills/` returns no guidance references.
