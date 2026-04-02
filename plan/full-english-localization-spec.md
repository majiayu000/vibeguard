# Full English Localization Spec

## Goal
Convert the entire repository to English by removing all Chinese text from source files, runtime messages, tests, docs, workflows, and skill descriptions.

## Scope
- In scope:
  - Runtime outputs and guard/hook messages (`hooks/`, `guards/`, `scripts/`)
  - Test assertions and fixtures (`tests/`)
  - Documentation and command guides (`docs/`, `.claude/`, `README.md`, etc.)
  - Workflow and skill docs (`workflows/`, `skills/`, `agents/`, `rules/`, `templates/`)
- Out of scope:
  - Behavioral logic changes unrelated to localization
  - Renaming file paths unless required

## Constraints
- Preserve code behavior and syntax.
- Keep placeholders and variables intact (`${VAR}`, `$VAR`, format tokens, rule IDs).
- Keep output semantics equivalent while changing language.
- Ensure no Han characters remain in tracked repository files.

## Plan
1. Build baseline inventory of files containing Han characters.
2. Apply automated line-level translation with caching and normalization.
3. Re-scan and iteratively patch remaining Han content.
4. Run regression tests and fix localization-caused assertion mismatches.
5. Produce final verification report.

## Done When
- `rg -n --hidden -g '!.git' -P '[\p{Han}]'` returns zero matches.
- Key test suites pass after localization updates.
- Runtime-facing messages are English-only.
