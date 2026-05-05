# SPEC: Canonical Prompt Contract Schema (#96, reduced scope)

**Status**: Draft v2 (post-#124/#125/#118 merge — scope reduced to lint-only)
**Closes**: #96 (P2, dx)
**Depends on**: nothing
**Blocks**: #99 (delegation contracts must target this contract)

---

## What changed since v1

The original SPEC (v1) was written before the recent merges. Three commits this week ate ~30-40% of the original scope:

| #96 sub-problem | v1 plan | Status today | Why |
|---|---|---|---|
| Chat / output contract | new section + validator | **DONE upstream** | #124 added a canonical Chat Contract block, locked across `claude-md/vibeguard-rules.md`, `templates/AGENTS.md`, `docs/CLAUDE.md.example` with an idempotency test |
| Routing contract + handoff schema | new section + handoff fields | **DONE upstream** | #125 published `workflows/references/routing-contract.md` with the 5-field handoff (mode / artifacts / verification_owner / stop_conditions / lane_map) |
| Size-budget drift detection | new validator | **DONE upstream** | #118 added W-19 + `check_doc_overload.sh` — line budget + prohibition-pairing |
| **Section-presence drift** | new validator | **STILL OPEN** | no one validates that AGENTS.md actually contains the required sections |
| **Role-prompt frontmatter contract** | new validator | **STILL OPEN** | the 14 files under `agents/` have YAML frontmatter but no shared schema |
| **CI integration** | wire into `local-contract-check.sh` | **STILL OPEN** | depends on the two items above |

So this revision is **lint-only** and shrinks to ~5-6 files.

---

## Goals (after scope reduction)

1. Catch the case where someone deletes or renames a required section in `templates/AGENTS.md` and prompt-driven behavior silently regresses.
2. Catch the case where a role prompt under `agents/` is missing one of the four mandatory frontmatter keys.
3. Run both checks in CI alongside the existing manifest validator.

## Non-goals

- Not adding new sections to AGENTS.md.
- Not enforcing prose content beyond "the section heading is present".
- Not validating skill `SKILL.md` files (separate contract surface).
- Not changing routing or chat contract content — those are already canonical.

---

## Design

### Decision: heading names are the contract (no HTML comment markers)

Per your pushback on the v1 marker proposal: drop the HTML comments. The contract becomes the literal Markdown heading names. Validator just looks for `^## Operating Principles$`, etc.

**Tradeoff accepted**: this requires a small AGENTS.md heading rename. The current 8 headings consolidate into 5 required + 2 optional sections that match the issue's section list:

| Current heading | Becomes |
|---|---|
| `## Chat Contract` | `## Output Contract` |
| `## Constraints` + `## Negative Constraints` | `## Operating Principles` (with `### Rules` and `### Prohibitions`) |
| `## Verification` | `## Verification` (unchanged) |
| `## Architecture Layers` + `## Fix Priority` | `## Routing` |
| `## Code Style` | `## Code Style` (optional, unchanged) |
| `## Guards` | `## Guards` (optional, unchanged) |

The `## Output Contract` rename has knock-on effect: #124's idempotency test currently anchors on `## Chat Contract`. The schema owns the rename; that test must update its anchor. Three files affected (`claude-md/vibeguard-rules.md` / `templates/AGENTS.md` / `docs/CLAUDE.md.example`).

> If you prefer to keep the heading `## Chat Contract` as-is, the schema can map `output-contract` → `## Chat Contract` literally. Then no rename is needed and #124's anchor stays. Cleaner; recommend this path. **See Open Question 1.**

### Schema file: `schemas/prompt-contract.schema.yaml`

```yaml
# Authoritative section list. Validator is the only consumer.
prompt_contract:
  version: 1

  required_sections:
    # heading_text is the literal Markdown heading the validator searches for.
    # name is the contract identity used in error messages and cross-refs.
    - name: operating-principles
      heading_text: "Operating Principles"
      must_mention:        # safety subset — case-insensitive substring
        - "force push"
        - "secret"
        - "AI marker"
    - name: routing
      heading_text: "Routing"
    - name: verification
      heading_text: "Verification"
    - name: output-contract
      heading_text: "Chat Contract"   # or "Output Contract" — see Open Q 1

  optional_sections:
    - name: code-style
      heading_text: "Code Style"
    - name: guards
      heading_text: "Guards"
    - name: negative-constraints
      heading_text: "Negative Constraints"

  role_prompt:
    frontmatter_required:
      - name
      - description
      - model
      - tools

  budgets:
    root_agents_md_warn_lines: 150
    root_agents_md_max_lines: 300
    role_prompt_max_lines: 400
```

### Validator: extend `scripts/lib/vibeguard_manifest.py`

New subcommand `validate-prompt-contract`. Inputs:
- `--target` (default `templates/AGENTS.md`); also accepts `agents/*.md` for role prompts
- `--schema` (default `schemas/prompt-contract.schema.yaml`)
- `--strict` — warnings become errors; used in CI

Checks:
1. Each `required_sections[].heading_text` appears as exactly one `^## ` heading.
2. `must_mention` tokens appear inside the matched section's body (case-insensitive substring).
3. Any `^## ` heading not in required + optional list raises a warning ("unknown section"), not an error — leaves room for project-local extensions without code change.
4. When `--target` is under `agents/`, parse YAML frontmatter and assert `role_prompt.frontmatter_required` keys are present.
5. Line count vs. `budgets.*` — warn / fail with `--strict`.

Output mirrors the existing manifest validator: human summary on stdout, exit 0/1.

### CI hook: `scripts/ci/validate-prompt-contract.sh`

~15 lines. Runs the validator on:
- `templates/AGENTS.md`
- every `agents/*.md`

Appends one line to `scripts/local-contract-check.sh` so local + CI share behavior.

### Tests: `tests/test_prompt_contract.sh`

~120 lines, same shell-test pattern as `test_manifest_contract.sh`. Cases:

- happy path on real `templates/AGENTS.md`
- missing `Operating Principles` heading → fail
- missing `force push` token in operating principles body → fail
- unknown section heading → warn (exit 0 without `--strict`)
- role prompt missing `model:` → fail under `--target agents/sample.md`
- AGENTS.md > 300 lines → fail in `--strict`
- AGENTS.md > 150 lines and ≤ 300 → warn only

---

## File touch list

| New | Purpose | ~LOC |
|---|---|---|
| `schemas/prompt-contract.schema.yaml` | source of truth | 35 |
| `scripts/ci/validate-prompt-contract.sh` | CI wrapper | 15 |
| `tests/test_prompt_contract.sh` | regression coverage | 120 |
| `docs/prompt-contract.md` | one-pager for humans | 60 |

| Modified | Change | ~LOC |
|---|---|---|
| `scripts/lib/vibeguard_manifest.py` | add `validate-prompt-contract` subcommand | +180 |
| `scripts/local-contract-check.sh` | append one validator call | +3 |
| `templates/AGENTS.md` | merge `Constraints` + `Negative Constraints` → `Operating Principles` (with subheadings); merge `Architecture Layers` + `Fix Priority` → `Routing`. Prose unchanged. | ~10 line moves |

Total: **4 new + 3 modified = 7 files**, ~430 LOC net.

If we keep `## Chat Contract` (Open Q 1 → recommended): drop the AGENTS.md migration to a 1-commit minor heading consolidation; ~6 files net.

---

## Acceptance criteria

1. `bash scripts/ci/validate-prompt-contract.sh` exits 0 on current main after the heading consolidation commit.
2. Removing the `Verification` heading on a fixture exits 1.
3. `bash tests/test_prompt_contract.sh` passes (full suite, including the budget warn/fail boundary).
4. `bash scripts/local-contract-check.sh --quick` includes prompt-contract validation.
5. `docs/prompt-contract.md` documents schema location, heading list, role frontmatter rules, precedence chain, how to add an optional section.
6. The AGENTS.md heading consolidation commit changes only headings; prose unchanged. Diff reviewable as pure structural rename.

---

## Open questions (need your input before I implement)

1. **Heading rename**: keep `## Chat Contract` (no AGENTS.md anchor break, no #124 anchor break) **or** rename to `## Output Contract` (matches issue #96's section list literally). **Recommend keep `Chat Contract`** — cheaper and zero collateral.
2. **Heading slug for `Operating Principles`**: keep two subheadings (`### Rules` + `### Prohibitions`) or flatten to one block? Recommend keep two — it preserves the current information structure.
3. **`must_mention` token list**: I proposed `force push / secret / AI marker`. Add `dependency injection` / `auto-fix` / anything else you want guaranteed in operating-principles? Default: those three are enough.
4. **Role frontmatter scope**: validate the 4 keys only, or also assert `tools` is a known subset? Recommend 4 keys only this PR; subset enforcement is a follow-up.
5. **Schema version**: include `version: 1` field; validator refuses to run on unknown version. Cheap insurance, recommend yes.

---

## Out of scope (explicit)

- Refactoring or rewriting any role prompt in `agents/`.
- Adding new required sections beyond what already exists.
- Validating skill `SKILL.md` frontmatter.
- Any runtime behavior — this PR is **lint-only**.

## Verification commands the implementer must run before claiming done

```
python3 -m py_compile scripts/lib/vibeguard_manifest.py
bash scripts/ci/validate-prompt-contract.sh
bash tests/test_prompt_contract.sh
bash scripts/local-contract-check.sh --quick
```

All four must exit 0.
