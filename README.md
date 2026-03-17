# VibeGuard

[![CI](https://github.com/majiayu000/vibeguard/actions/workflows/ci.yml/badge.svg)](https://github.com/majiayu000/vibeguard/actions/workflows/ci.yml)

**Stop AI from hallucinating code.**

[中文文档](README_CN.md)

When using Claude Code or Codex, AI frequently invents non-existent APIs, reinvents the wheel, hardcodes fake data, and over-engineers solutions. VibeGuard prevents these problems at the source through **rule injection + real-time interception + static scanning** — three layers of defense.

Inspired by [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) and [Stripe Minions](https://www.youtube.com/watch?v=bZ0z1ApYjJo). Fully implements all 5 Harness Golden Principles.

## The Problem

```
You:  "Add a login endpoint"
AI:   Creates auth_service.py (duplicate of existing auth.py)
      Imports non-existent library `flask-auth-magic`
      Hardcodes JWT secret as "your-secret-key"
      Adds 200 lines of "improvements" you didn't ask for
```

**VibeGuard catches all of these — automatically, before they reach your codebase.**

## Quick Start

```bash
git clone https://github.com/majiayu000/vibeguard.git ~/vibeguard
bash ~/vibeguard/setup.sh
```

Open a new Claude Code session. Done. Run `bash ~/vibeguard/setup.sh --check` to verify.

## How It Works

### 1. Rule Injection (active from session start)

88 rules loaded via Claude Code's native rules system (`~/.claude/rules/vibeguard/`), directly influencing AI reasoning. Plus a 7-layer constraint index injected into `~/.claude/CLAUDE.md`:

| Layer | Constraint | Effect |
|-------|-----------|--------|
| L1 | Search before create | Must search for existing implementations before creating new files |
| L2 | Naming conventions | `snake_case` internally, `camelCase` at API boundaries, no aliases |
| L3 | Quality baseline | No silent exception swallowing, no `Any` types in public methods |
| L4 | Data integrity | No data = show blank, no hardcoding, no inventing APIs |
| L5 | Minimal changes | Only do what was asked, no unsolicited "improvements" |
| L6 | Process gates | Large changes require preflight, verify before done |
| L7 | Commit discipline | No AI markers, no force push, no secrets |

Rules use **negative constraints** ("X does not exist") to implicitly guide AI — more effective than positive descriptions (Golden Principle #5: give maps, not manuals).

### 2. Hooks — Real-Time Interception

No manual steps needed. Hooks trigger automatically during AI operations:

| Scenario | Hook | Result |
|----------|------|--------|
| AI creates new `.py/.ts/.rs/.go/.js` file | `pre-write-guard` | **Block** — must search first |
| AI runs `git push --force`, `rm -rf`, `reset --hard` | `pre-bash-guard` | **Block** — suggests safe alternatives |
| AI edits non-existent file | `pre-edit-guard` | **Block** — must Read file first |
| AI adds `unwrap()`, hardcoded paths | `post-edit-guard` | **Warn** — with fix instructions |
| AI adds `console.log` / `print()` debug statements | `post-edit-guard` | **Warn** — use logger instead |
| `git commit` | `pre-commit-guard` | **Block** — quality + build checks (staged files only), 10s timeout |
| AI tries to finish with unverified changes | `stop-guard` | **Gate** — complete verification first |
| Session ends | `learn-evaluator` | **Evaluate** — collect metrics, detect correction signals |

### 3. MCP Tools (on-demand)

AI can proactively call these tools to check code quality:

- `guard_check` — run language-specific guard scripts (`python | rust | typescript | javascript | go | auto`)
- `compliance_report` — project compliance check
- `metrics_collect` — collect code metrics

## Slash Commands

10 custom commands covering the full development lifecycle:

| Command | Purpose |
|---------|---------|
| `/vibeguard:preflight` | Generate constraint set before changes |
| `/vibeguard:check` | Full guard scan + compliance report |
| `/vibeguard:review` | Structured code review (security → logic → quality → perf) |
| `/vibeguard:cross-review` | Dual-model adversarial review (Claude + Codex) |
| `/vibeguard:build-fix` | Build error resolution |
| `/vibeguard:learn` | Generate guard rules from errors / extract Skills from discoveries |
| `/vibeguard:interview` | Deep requirements interview → SPEC.md |
| `/vibeguard:exec-plan` | Long-running task execution plan, cross-session resume |
| `/vibeguard:gc` | Garbage collection (log archival + worktree cleanup + code slop scan) |
| `/vibeguard:stats` | Hook trigger statistics |

Shortcuts: `/vg:pf` `/vg:gc` `/vg:ck` `/vg:lrn`

### Complexity Routing

| Scope | Flow |
|-------|------|
| 1-2 files | Just implement |
| 3-5 files | `/vibeguard:preflight` → constraints → implement |
| 6+ files | `/vibeguard:interview` → SPEC → `/vibeguard:preflight` → implement |

## Guard Scripts

Standalone static analysis — run these on any project:

```bash
# Universal
bash ~/vibeguard/guards/universal/check_code_slop.sh /path/to/project     # AI code slop
python3 ~/vibeguard/guards/universal/check_dependency_layers.py /path      # dependency direction
python3 ~/vibeguard/guards/universal/check_circular_deps.py /path          # circular deps

# Rust
bash ~/vibeguard/guards/rust/check_unwrap_in_prod.sh /path                 # unwrap/expect in prod
bash ~/vibeguard/guards/rust/check_nested_locks.sh /path                   # deadlock risk
bash ~/vibeguard/guards/rust/check_declaration_execution_gap.sh /path      # declared but not wired

# Go
bash ~/vibeguard/guards/go/check_error_handling.sh /path                   # unchecked errors
bash ~/vibeguard/guards/go/check_goroutine_leak.sh /path                   # goroutine leaks
bash ~/vibeguard/guards/go/check_defer_in_loop.sh /path                    # defer in loop

# TypeScript
bash ~/vibeguard/guards/typescript/check_any_abuse.sh /path                # any type abuse
bash ~/vibeguard/guards/typescript/check_console_residual.sh /path         # console.log residue

# Python
python3 ~/vibeguard/guards/python/check_naming_convention.py /path         # camelCase mix
python3 ~/vibeguard/guards/python/check_dead_shims.py /path                # dead re-export shims
```

Supports `// vibeguard:ignore` inline comments to skip specific lines.

## Multi-Agent Dispatch

14 specialized agents + 1 dispatcher with automatic routing:

| Agent | Purpose |
|-------|---------|
| `dispatcher` | **Auto-route** — analyzes task type, routes to best agent |
| `planner` / `architect` | Requirements analysis, system design |
| `tdd-guide` | RED → GREEN → IMPROVE test-driven development |
| `code-reviewer` / `security-reviewer` | Layered code review, OWASP Top 10 |
| `build-error-resolver` | Build error diagnosis and fix |
| `go-reviewer` / `python-reviewer` / `database-reviewer` | Language-specific review |
| `refactor-cleaner` / `doc-updater` / `e2e-runner` | Refactoring, docs, E2E tests |

## Observability

```bash
bash ~/vibeguard/scripts/quality-grader.sh          # Quality grade (A/B/C/D)
bash ~/vibeguard/scripts/stats.sh                    # Hook trigger stats (7 days)
bash ~/vibeguard/scripts/metrics-exporter.sh         # Prometheus metrics export
bash ~/vibeguard/scripts/doc-freshness-check.sh      # Rule-guard coverage check
```

## Learning System

Closed-loop learning — evolve defenses from mistakes:

**Mode A — Defensive** (learn from errors):
```
/vibeguard:learn <error description>
```
Analyzes root cause (5-Why) → generates new guard/hook/rule → verifies detection → same class of error never recurs.

**Mode B — Accumulative** (extract Skills from discoveries):
```
/vibeguard:learn extract
```
Extracts non-obvious solutions as structured Skill files for future reuse.

## Golden Principles Implementation

| Principle | From | Implementation |
|-----------|------|----------------|
| Automation over documentation | Harness #3 | Hooks + guard scripts enforce mechanically |
| Error messages = fix instructions | Harness #3 | Every interception tells AI how to fix, not just what's wrong |
| Maps not manuals | Harness #5 | 32-line index + negative constraints + lazy loading |
| Failure → capability | Harness #2 | Mistake → learn → new guard → never again |
| If agent can't see it, it doesn't exist | Harness #1 | All decisions written to repo (CLAUDE.md / ExecPlan) |
| Give agent eyes | Harness #4 | Observability stack (logs + metrics + alerts) |

## Also Works With

| Tool | How |
|------|-----|
| **OpenAI Codex** | `cp ~/vibeguard/templates/AGENTS.md ./AGENTS.md` |
| **Docker** | `docker pull ghcr.io/majiayu000/vibeguard:latest` |
| **Any project** | `cp ~/vibeguard/docs/CLAUDE.md.example ./CLAUDE.md` (rules only, no hooks) |

## Installation Options

```bash
bash ~/vibeguard/setup.sh                    # Install (default: core profile)
bash ~/vibeguard/setup.sh --profile full     # Full: adds Stop Gate + Build Check + Pre-Commit
bash ~/vibeguard/setup.sh --check            # Verify installation
bash ~/vibeguard/setup.sh --clean            # Uninstall
```

## References

- [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/)
- [Stripe Minions](https://www.youtube.com/watch?v=bZ0z1ApYjJo)
- [Anthropic: Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)

---

[中文文档 / Chinese Documentation →](README_CN.md)
