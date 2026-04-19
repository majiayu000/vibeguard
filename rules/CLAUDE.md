# rules/ directory

VibeGuard rule files define inspection standards for each language and domain.

## Rule ID naming convention

| prefix | realm | example |
|------|------|------|
| `U-XX` | General rules (applies to all languages) | U-11 hardcoded paths |
| `RS-XX` | Rust-specific rules | RS-03 unwrap/expect |
| `TS-XX` | TypeScript specific rules | TS-01 any abuse |
| `PY-XX` | Python-specific rules | PY-01 naming convention |
| `SEC-XX` | Security Rules | SEC-01 Key Disclosure |

## File structure

- `rules/claude-rules/**` — canonical English rule source (author here first)
- `universal.md` — generated common code-style, cross-entry, and workflow summary
- `rust.md` — Rust language rules
- `typescript.md` — TypeScript language rules
- `python.md` — Python language rules
- `security.md` — security related rules

## Each rule contains

1. ID and name
2. Severity (high/medium/low)
3. Description of inspection items
4. Repair mode (specific code repair method)
5. FIX/SKIP judgment matrix

## Generation

`rules/*.md` and `docs/rule-reference.md` are generated from `rules/claude-rules/**` via `python3 scripts/generate_rule_docs.py`.
