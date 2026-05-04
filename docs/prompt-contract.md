# Prompt Contract

VibeGuard validates the structure of `templates/AGENTS.md` and every role prompt under `agents/` against `schemas/prompt-contract.schema.json`. The schema is the only source of truth — the validator is the only consumer.

## What is enforced

| Check | Default | `--strict` |
|---|---|---|
| Each `required_sections[].heading_text` appears as a top-level `## ` heading | error | error |
| Each `must_mention` token appears in the matched section body (case-insensitive substring) | error | error |
| Top-level `## ` heading not in required + optional list | warning | warning |
| Role prompt under `agents/` declares all `role_prompt.frontmatter_required` keys | error | error |
| `templates/AGENTS.md` exceeds `budgets.root_agents_md_warn_lines` | warning | warning |
| `templates/AGENTS.md` exceeds `budgets.root_agents_md_max_lines` | warning | error |
| Role prompt exceeds `budgets.role_prompt_max_lines` | warning | error |

## Required sections (today)

| name | heading_text | safety subset |
|---|---|---|
| `operating-principles` | `Operating Principles` | must mention `force push`, `secret`, `AI marker` |
| `routing` | `Routing` | — |
| `verification` | `Verification` | — |
| `output-contract` | `Chat Contract` | — |

## Optional sections

`Code Style`, `Guards`. Add an optional section by appending to `optional_sections` in the schema; existing AGENTS.md does not need to change.

## Role prompt contract

Files matched by `agents/*.md` must declare YAML frontmatter with `name`, `description`, `model`, `tools`. The validator only checks key presence; value types are not enforced in this revision.

## How to run

```bash
# Single target, warnings allowed
python3 scripts/lib/vibeguard_manifest.py validate-prompt-contract \
  --target templates/AGENTS.md

# Walk all prompts (CI default)
bash scripts/ci/validate-prompt-contract.sh

# Treat warnings as errors
bash scripts/ci/validate-prompt-contract.sh --strict
```

The CI wrapper validates `templates/AGENTS.md` plus every `agents/*.md` and exits non-zero if any target fails.

## Adding a new required section

1. Add a `{name, heading_text}` entry to `required_sections` in `schemas/prompt-contract.schema.json`.
2. Update `templates/AGENTS.md` to include the new heading.
3. Add a regression case to `tests/test_prompt_contract.sh` that asserts the section is required.

## Schema versioning

The schema includes a `version` field. The validator refuses to run on a version it does not recognize. Bump `version` and update the validator together when the schema shape changes.

## Precedence (informational)

Effective prompt rules are resolved in this order, with later layers winning on conflict:

1. `templates/AGENTS.md` (project root)
2. Role prompt under `agents/<role>.md`
3. Skill-specific instructions in a `SKILL.md`
4. Runtime overlay (`AGENTS.override.md`, ad-hoc additions in session)

The validator only checks layer 1 and layer 2. Skill and overlay validation is out of scope for this contract.
