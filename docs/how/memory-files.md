# Memory Files — AI context memory mechanism

Claude Code loads several memory surfaces automatically at session start. VibeGuard builds on top of them so that behavior constraints, reusable rules, and project memory persist across sessions.

Codex uses a different product contract. It automatically assembles user
instructions from `AGENTS.md` / `AGENTS.override.md`; its `~/.codex/rules/*.rules`
files are command execution policy files, not model-visible rule documents.

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
│   ├── agent-harness-audit.md
│   ├── coding-style.md
│   ├── data-consistency.md
│   ├── eval-validation.md
│   ├── execution-pinning.md
│   ├── fact-inference-separation.md
│   ├── long-horizon-reliability.md
│   ├── no-silent-degradation.md
│   ├── publish-action-confirmation.md
│   ├── security.md
│   ├── vibe-coding-production.md
│   └── workflow.md
├── rust/
│   ├── quality.md
│   └── struct-field-change-checklist.md
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

## Claude Code and Codex rule loading

Claude Code has a native rule-loading surface. Markdown files under
`.claude/rules/` and `~/.claude/rules/` are discovered recursively. Rules
without `paths` frontmatter are loaded at launch; path-scoped rules load when
Claude reads matching files. VibeGuard uses this by symlinking
`rules/claude-rules/**` into `~/.claude/rules/vibeguard/`.

Example language rule:

```yaml
---
paths: **/*.rs,**/Cargo.toml,**/Cargo.lock
---
```

That is why Claude Code appears to load language-specific VibeGuard rules: the
runtime matches task files against `paths`, not because the model guesses a
language from the prompt.

Codex does not currently have an equivalent native markdown rule directory. Its
durable reasoning surface is:

- global `~/.codex/AGENTS.md`
- repo-level `AGENTS.md`
- deeper `AGENTS.md` / `AGENTS.override.md` files closer to the working
  directory

For VibeGuard, the practical Codex path is therefore a rule compiler: parse the
Claude-style rule source under `rules/claude-rules/**`, select the rules that
match the requested languages or project files, and render a compact
Codex-friendly bundle into `AGENTS.md` rather than relying on `~/.codex/rules/`.

References:

- Claude Code memory and rules: <https://code.claude.com/docs/en/memory>
- Claude Code `.claude` directory: <https://code.claude.com/docs/en/claude-directory>

## Relationship with hooks

Memory files influence the reasoning layer. Hooks influence the execution layer.

- Rules tell the agent what is allowed and what to avoid.
- Hooks inspect what the agent actually tried to do.
- Logs and project memory close the loop so recurring failures can become new rules, hooks, or skills.

That combination is the core VibeGuard pattern: constrain early, intercept late, and learn from misses.
