# Memory Files — AI context memory mechanism

Claude Code loads several memory surfaces automatically at session start. VibeGuard builds on top of them so that behavior constraints, reusable rules, and project memory persist across sessions.

## Three file classes, three responsibilities

### 1. `CLAUDE.md` — Constitution

Typical locations:

- Global: `~/.claude/CLAUDE.md`
- Project: `./CLAUDE.md` or `./.claude/CLAUDE.md`
- Local/private overlays when supported by the toolchain

Role: define the operating contract for the agent.

Common contents:

- Communication and collaboration rules
- Git / commit / release discipline
- Project-specific build and test commands
- VibeGuard's seven-layer defense summary and local constraints

Priority: high. More specific CLAUDE files usually override broader ones.

### 2. Native rules — Law

Path: `~/.claude/rules/vibeguard/`

VibeGuard installs native rule files under `common/`, `rust/`, `golang/`, `typescript/`, and `python/`.

```text
~/.claude/rules/vibeguard/
├── common/
│   ├── coding-style.md
│   ├── data-consistency.md
│   ├── fact-inference-separation.md
│   ├── no-silent-degradation.md
│   ├── publish-action-confirmation.md
│   ├── security.md
│   └── workflow.md
├── rust/quality.md
├── golang/quality.md
├── typescript/quality.md
└── python/
    ├── quality.md
    └── pydantic-boundary.md
```

`common/` rules are loaded broadly. Language-specific rules are scoped through YAML frontmatter `paths` so only relevant files pull them into context.

### 3. Project memory — Experience notebook

Common path patterns:

- Claude Code project memory under `~/.claude/projects/...`
- OMX runtime memory under `.omx/`
- Repository-local notes such as `memory.md` or plan files when a workflow uses them

Role: preserve decisions, open questions, completed remediation work, and reusable local knowledge.

## How the layers work together

```text
Session start
  ├─ Load CLAUDE.md        → baseline operating contract
  ├─ Load native rules     → language/domain constraints
  └─ Load project memory   → prior decisions and local context
```

If more detail is needed, the agent can then load linked docs, plans, or project memory files on demand.

## Relationship with hooks

Memory files influence the reasoning layer. Hooks influence the execution layer.

- Rules tell the agent what is allowed and what to avoid.
- Hooks inspect what the agent actually tried to do.
- Logs and project memory close the loop so recurring failures can become new rules, hooks, or skills.

That combination is the core VibeGuard pattern: constrain early, intercept late, and learn from misses.
