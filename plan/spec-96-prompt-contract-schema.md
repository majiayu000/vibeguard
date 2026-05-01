# SPEC: Canonical Prompt Contract Schema (#96)

**Status**: Draft for review
**Author**: majiayu000
**Date**: 2026-04-30
**Closes**: #96 (P2, dx)
**Depends on**: nothing
**Blocks**: #99 (delegation contracts must target this contract)

---

## Goals (Facts from #96)

1. Replace the conventional shape of `templates/AGENTS.md` with a machine-validatable schema.
2. Give role prompts and runtime overlays stable extension points instead of ad hoc text insertion.
3. Catch prompt-contract drift in CI the same way `validate-manifest-contract.sh` catches manifest drift today.

## Non-goals

- Not rewriting AGENTS.md content. The schema describes the shape; current prose stays unless it violates the shape.
- Not introducing a new prompt language or DSL. Markdown + minimal HTML-comment markers + one YAML schema file.
- Not formalizing every role in `agents/` in this PR. SEC-only: role prompts get one optional convention (frontmatter contract); deep role schema is a follow-up.

---

## Current state (Facts; from sub-agent survey)

- `templates/AGENTS.md` is **67 lines**, eight headings: `Chat Contract`, `Constraints`, `Negative Constraints`, `Verification`, `Architecture Layers`, `Fix Priority`, `Code Style`, `Guards`. **No machine-readable markers.**
- `skills/vibeguard/references/task-contract.yaml` (58 lines) is the existing precedent for a YAML schema (top-level `task_contract` with `required`/`forbidden`/`warnings`/`validation`).
- `scripts/local-contract-check.sh` orchestrates ~7 sub-validators; **none of them touch AGENTS.md**.
- `scripts/ci/validate-manifest-contract.sh` calls `scripts/lib/vibeguard_manifest.py validate` — natural integration point.
- `agents/` has 14 role prompts in YAML-frontmatter + Markdown form, no shared schema.
- `docs/reference/harness-engineering.md:178-189` already prescribes "AGENTS.md ≈ 100 lines, catalogue not encyclopedia, progressive disclosure" — schema must be consistent with this.

## Inference (medium confidence)

- The issue's suggested section list (operating principles, routing, verification, safety, output) maps onto the current AGENTS.md headings with one rename and one merge:
  - `Constraints` + `Negative Constraints` → **operating-principles** (rules + prohibitions)
  - `Architecture Layers` + `Fix Priority` → **routing** (where to apply the rules + ordering)
  - `Verification` → **verification** (no change)
  - `Negative Constraints` (force-push, AI tags, etc.) is also **safety** — overlap is intentional, schema treats safety as a *required subset* of operating-principles, not a separate top-level section
  - `Chat Contract` → **output-contract**
- `Guards` and `Code Style` are repo-specific addenda; schema treats them as **optional named sections**.

## Suggestion: Schema design

### File: `schemas/prompt-contract.schema.yaml` (new)

Single YAML file describing required/optional sections, marker syntax, and precedence.

```yaml
# Authoritative list of section anchors that AGENTS.md and role prompts may declare.
# Validator reads this file; nothing else hardcodes section names.

prompt_contract:
  version: 1
  required_sections:
    - operating-principles      # rules + prohibitions; safety subset must be present
    - routing                   # where rules apply, application order
    - verification              # commands that prove "done"
    - output-contract           # chat shape, verbosity, formatting
  optional_sections:
    - guards                    # repo-specific guard scripts
    - code-style                # repo-specific style addenda
    - role-overrides            # only valid in role prompts, not root AGENTS.md
  safety_subset:
    # operating-principles must contain a block tagged safety with at least these prohibitions
    # validator looks for these exact tokens (case-insensitive substring match)
    must_mention:
      - "force push"
      - "secret"
      - "AI tag"
  marker_syntax:
    open:  "<!-- contract:{section} -->"
    close: "<!-- /contract:{section} -->"
    role_frontmatter_required:
      - name
      - description
      - model
      - tools
  precedence:
    # higher number wins on conflict; documented for humans, not enforced by validator
    1: root_agents_md         # templates/AGENTS.md
    2: role_prompt            # agents/*.md
    3: skill_instructions     # skills/*/SKILL.md
    4: runtime_overlay        # AGENTS.override.md, ad-hoc additions in session
  budgets:
    root_agents_md_max_lines: 200    # warn at 150
    role_prompt_max_lines: 400        # warn at 250
```

### Marker convention (additive, doesn't break existing AGENTS.md rendering)

Each required section is wrapped:

```markdown
<!-- contract:operating-principles -->
## Constraints
| Layer | Rule |
| ...

## Negative Constraints
- No force push to main
- ...
<!-- /contract:operating-principles -->
```

- HTML comments are invisible in rendered Markdown — no visual change.
- Validator parses the open/close pairs, not the heading text — heading rename is safe.
- Multiple Markdown headings can sit inside one contract block (e.g. `Constraints` + `Negative Constraints` both inside `operating-principles`).

### Validator: `scripts/lib/vibeguard_manifest.py validate-prompt-contract`

New subcommand on the existing CLI (Suggestion: extend, don't fork).

Inputs:
- `--target` path: defaults to `templates/AGENTS.md`; can also point at `agents/*.md` to validate a role prompt.
- `--schema`: defaults to `schemas/prompt-contract.schema.yaml`.
- `--strict`: warnings become errors. Used in CI.

Checks (in order):
1. **Marker integrity**: every `<!-- contract:X -->` has a matching `<!-- /contract:X -->`. Nested unrelated sections allowed; nested same-name forbidden.
2. **Required section presence**: every section in `required_sections` appears at least once.
3. **Unknown section rejection**: any `contract:` marker whose name is not in required/optional list is an error.
4. **Safety subset**: inside `operating-principles`, every token in `safety_subset.must_mention` must appear (case-insensitive substring).
5. **Role frontmatter** (only when `--target` is under `agents/`): YAML frontmatter contains all `role_frontmatter_required` keys.
6. **Budget**: line count vs. `budgets.*` — exceeding the warn threshold prints a warning, exceeding the max fails in `--strict`.

Output format mirrors existing manifest validator: human summary on stdout, exit code 0/1.

### Hookup

- New file `scripts/ci/validate-prompt-contract.sh` (~12 lines) wraps the Python subcommand for both `templates/AGENTS.md` and every `agents/*.md`.
- Append one line to `scripts/local-contract-check.sh` so local + CI share behavior.

### Tests

- New `tests/test_prompt_contract.sh` (~150 lines) using the same shell test pattern as `test_manifest_contract.sh`. Cover: missing marker, mismatched marker, unknown section name, missing safety subset, budget warn vs. fail, role frontmatter missing key, happy path on the real `templates/AGENTS.md`.

### Migration of existing files

One commit: wrap the eight current AGENTS.md headings in their five contract blocks. **No content changes**. Diff is purely additive (HTML comments).

---

## File touch list (Suggestion; reviewable scope)

| New | Purpose |
|---|---|
| `schemas/prompt-contract.schema.yaml` | source of truth for the schema |
| `scripts/ci/validate-prompt-contract.sh` | CI wrapper |
| `tests/test_prompt_contract.sh` | regression coverage |
| `docs/prompt-contract.md` | one-pager for humans (≤80 lines) |

| Modified | Change |
|---|---|
| `templates/AGENTS.md` | wrap existing headings in 5 contract markers |
| `scripts/lib/vibeguard_manifest.py` | add `validate-prompt-contract` subcommand |
| `scripts/local-contract-check.sh` | append one call into the new validator |
| `rules/claude-rules/common/coding-style.md` | add U-XX rule cross-referencing the schema (optional) |

Total: 4 new + 3-4 modified = **7-8 files**.

---

## Acceptance criteria (Done-when)

1. `bash scripts/ci/validate-prompt-contract.sh` exits 0 on `templates/AGENTS.md` after marker migration.
2. `bash scripts/ci/validate-prompt-contract.sh` exits 1 on a fixture with missing `verification` marker.
3. `bash tests/test_prompt_contract.sh` passes (full suite, including budget warn/fail boundary cases).
4. `bash scripts/local-contract-check.sh --quick` includes prompt-contract validation.
5. CI workflow runs the validator on every PR (existing `validate-manifest-contract.sh` step extends or new step added).
6. `docs/prompt-contract.md` documents: schema location, marker syntax, how to add a new optional section, precedence chain.
7. No content drift: the AGENTS.md migration commit only adds 5 pairs of HTML comment markers, no prose edits.

---

## Open questions (need your input before I implement)

1. **Marker syntax**: HTML comment `<!-- contract:X -->` vs. fenced YAML block `<!-- contract:X yaml --> ... <!-- /contract --> ` (the latter would let us embed structured data inside a section). Recommendation: HTML comment only — keeps the diff additive and avoids two parsers.
2. **Where to live**: `schemas/prompt-contract.schema.yaml` (sibling of existing `schemas/install-modules.json`) vs. `skills/vibeguard/references/prompt-contract.yaml` (sibling of `task-contract.yaml`). Recommendation: `schemas/` — it's a contract, not a skill reference, and CI already reads from `schemas/`.
3. **Budget thresholds**: `root_agents_md_max_lines: 200` proposed. Current is 67 lines, so plenty of headroom. Acceptable?
4. **Role frontmatter check scope**: validate only the four core keys (name/description/model/tools), or also enforce `tools` is a known subset? Recommendation: core four only in this PR; subset enforcement is a follow-up.
5. **Should the schema version itself**? Proposed `version: 1` field with the validator refusing to run if it doesn't recognize the version. Recommendation: yes, cheap insurance.

---

## Out of scope (explicit)

- Refactoring or rewriting any role prompt in `agents/`.
- Adding new required sections to AGENTS.md beyond what already exists.
- Validating skill SKILL.md frontmatter — that is a separate contract.
- Adding any runtime behavior; this PR is **lint-only**.

---

## Verification commands the implementer must run before claiming done

```
python3 -m py_compile scripts/lib/vibeguard_manifest.py
bash scripts/ci/validate-prompt-contract.sh
bash tests/test_prompt_contract.sh
bash scripts/local-contract-check.sh --quick
```

All four must exit 0.
