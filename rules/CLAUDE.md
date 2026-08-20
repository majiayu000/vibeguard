<!-- Generated from docs/directory-guidance.md; do not edit directly. -->

# rules/ directory

VibeGuard rule files define inspection standards by language and domain.

| Prefix | Realm | Example |
|------|------|------|
| `U-XX` | Universal | U-11 hardcoded paths |
| `RS-XX` | Rust | RS-03 unwrap/expect |
| `TS-XX` | TypeScript/JavaScript | TS-01 any abuse |
| `PY-XX` | Python | PY-01 naming convention |
| `GO-XX` | Go | GO-01 error handling |
| `SEC-XX` | Security | SEC-01 key disclosure |

`rules/claude-rules/**` is the canonical English source. Author rule changes
there first. Top-level `rules/*.md` and `docs/rule-reference.md` are generated
with `python3 scripts/generate_rule_docs.py`.

Each rule needs an ID and name, severity, inspection description, specific
repair guidance, and a FIX/SKIP judgment matrix.
