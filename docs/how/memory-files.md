# Memory Files — AI context memory mechanism

Claude Code automatically loads a set of Memory Files into the context window every time a session is started. These files constitute the AI's "long-term memory" and do not require the user to repeat instructions each time.

## Three types of files, three responsibilities

### 1. CLAUDE.md — Constitution

Path: `~/.claude/CLAUDE.md` (global) + `project/.claude/CLAUDE.md` (project level)

Role: Define the basic code of conduct of AI, and all operations are bound by it.

What’s included:
- General behavior (communication in Chinese, no expansion of scope, no additional functions)
- Port allocation table (no conflicts)
- Git/PR specifications (no AI tags, DCO validation, rebase)
- Code rules (no hardcode, no inline import, single file limit of 200 lines)
- VibeGuard Seven Layers of Defense Summary

Priority: Highest. The instructions in CLAUDE.md override the AI's default behavior.

### 2. Rules — Law

Path: `~/.claude/rules/vibeguard/`

VibeGuard's 83 rules are loaded on demand through the `paths` field of YAML frontmatter:

```
~/.claude/rules/vibeguard/
├── common/
│ ├── coding-style.md # U-01~U-24 Universal constraints (valid globally)
│ ├── data-consistency.md # U-11~U-14 data consistency (valid globally)
│ └── security.md # SEC-01~SEC-10 security rules (valid globally)
├── rust/
│ └── quality.md # RS-01~RS-13 Rust rules (only *.rs files trigger)
├── golang/
│ └── quality.md # GO-01~GO-12 Go rules (only *.go files trigger)
├── typescript/
│ └── quality.md # TS-01~TS-12 TypeScript rules (only triggered by *.ts files)
└── python/
    └── quality.md # PY-01~PY-12 Python rules (only triggered by *.py files)
```

Rules under `common/` have no path restrictions and are loaded every time. Language rules are controlled through frontmatter:

```yaml
---
description: VibeGuard Rust Quality Rules
paths:
  - "**/*.rs"
  - "**/Cargo.toml"
---
```

Automatically load RS-* rules when editing Rust files, and do not load Python/TS rules to avoid context bloat.

### 3. MEMORY.md — Experience Notebook

Path: `~/.claude/projects/<project hash>/memory/MEMORY.md`

Function: Knowledge index for cross-session persistence. The experience, decisions, and discoveries that AI accumulates over multiple conversations.

Features:
- Automatically loaded into the context of every conversation
- Will be truncated after the first 200 lines, so keep it simple
- Link to detailed theme files (e.g. `harness-engineering.md`)
- Record completed improvement plans, architectural decisions, and critical paths

## Workflow

```
Conversation start
  ├─ Load CLAUDE.md → AI knows "what it can and cannot do"
  ├─ Load rules/vibeguard/ → AI knows "how to write code to comply with regulations"
  └─ Load MEMORY.md → AI knows "what has been done before and what has been decided"
      │
      ├─ Need more details? → Read theme files under memory/
      └─ Need historical context? → mcp__remem__search Search past decisions
```

## Contextual Economics

Memory files occupy a total of about 4.7k tokens (2.3% of the 200k window), which is extremely cost-effective:

| Category | tokens | Proportion | Value |
|------|--------|------|------|
| CLAUDE.md | ~2.2k | 1.1% | Code of conduct to avoid repeated corrections |
| common rules (3 files) | ~2.0k | 1.0% | Common part of 83 rules |
| MEMORY.md | ~0.4k | 0.2% | Cross-session knowledge index |
| Language rules (on demand) | ~0.3k/piece | 0.15% | Only loaded when editing the corresponding language |

## Relationship with Hook system

Memory files act on the reasoning layer (token level) of AI, and Hooks act on the execution layer (file system level). The two complement each other:

- **Rules tells AI "how it should be written"** → AI generates code that conforms to the specification
- **Hooks to check AI "what actually wrote"** → Block non-compliant edits

14 rules have two layers of protection (AI rules + guard scripts) at the same time, and the remaining 69 are pure AI constraints.
