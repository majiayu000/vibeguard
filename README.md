# VibeGuard

[![CI](https://github.com/majiayu000/vibeguard/actions/workflows/ci.yml/badge.svg)](https://github.com/majiayu000/vibeguard/actions/workflows/ci.yml)

**Stop Claude Code and Codex from making the same expensive mistakes twice.**

![VibeGuard project card](docs/assets/readme-card.png)

[Chinese Docs](docs/README_CN.md) · [Rule Reference](docs/rule-reference.md) · [Contributing](CONTRIBUTING.md)

VibeGuard adds **native rules + real-time hooks + static guards** to catch what AI coding agents get wrong — **before it reaches your codebase**:

- Duplicate files and reinvented modules
- Invented APIs, fake libraries, and hardcoded placeholder values
- Dangerous shell/git commands (`rm -rf`, `push --force`, `reset --hard`)
- Audited cleanup for intentional local discards, with exact path plans and confirmation gates
- Analysis paralysis and unverified "I'm done" claims
- Silent exception swallowing and `Any`-type abuse
- AI-slop patterns flagged on every commit

Works with **Claude Code** and **Codex CLI**.

## Install in 30 seconds

```bash
git clone https://github.com/majiayu000/vibeguard.git ~/vibeguard
bash ~/vibeguard/setup.sh
```

Requires Python 3 and Rust/Cargo for the `vibeguard-runtime` runtime binary.

Open a new Claude Code or Codex session. Run `bash ~/vibeguard/setup.sh --check` to verify.

## What you actually get

| Layer | What it does |
|-------|--------------|
| **Native Rules** | Bias the model away from bad decisions before it acts |
| **Hooks** | Block dangerous or low-quality actions in real time |
| **Static Guards** | Scan projects for AI-slop, duplicates, and structural issues |
| **Slash Commands** | `/vibeguard:*` workflows for preflight / review / check / learn |
| **Learning System** | Turn repeated AI mistakes into reusable defenses |
| **Observability** | Metrics and health for every interception |

## Product Boundaries

VibeGuard has two layers:

| Surface | Scope | Canonical Source |
|---------|-------|------------------|
| **VibeGuard Core** | Rules, hooks, static guards, install/runtime contract, observability | `rules/claude-rules/`, `schemas/install-modules.json`, `hooks/`, `guards/` |
| **VibeGuard Workflows** | Slash commands, agent prompts, planning/execution presets | `skills/`, `workflows/`, `agents/` |

If these surfaces disagree, treat the Core contract as authoritative first, then update workflow/docs surfaces to match it.

For repository layout ownership, see [Directory Map](docs/directory-map.md).

## What it looks like in practice

![VibeGuard demo](docs/assets/demo.gif)

```text
You:  "Add a login endpoint"

AI:   → tries to create auth_service.py
      ✗ VibeGuard blocks — duplicate of existing auth.py, search first

      → tries to import `flask-auth-magic`
      ✗ VibeGuard blocks — non-existent library, verify before adding

      → hardcodes JWT secret as "your-secret-key"
      ✗ VibeGuard flags — use env var or secret manager

      → runs `git push --force`
      ✗ VibeGuard denies — suggests `--force-with-lease`

      → runs `git clean -fd`
      ✗ VibeGuard denies — points to an authorized discard workflow with an exact deletion plan

      → keeps reading files without acting
      ⚠ VibeGuard escalates — force a concrete next step or report blocker

      → claims done without verifying
      ⚠ VibeGuard gates — run build/test before finishing
```

**Every interception returns a fix instruction**, not just a failure — so the agent can self-correct.

Re-record your own demo: see [docs/assets/README.md](docs/assets/README.md) (one command via asciinema + agg).

## Who this is for

Use VibeGuard if you:

- Use Claude Code or Codex regularly
- Have seen duplicate files, fake APIs, over-engineering, or unverified "done" claims
- Want **mechanical enforcement**, not just prompt guidelines

It may be overkill if you only use AI occasionally or don't want hook-level interception.

Inspired by [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) and [Stripe Minions](https://www.youtube.com/watch?v=bZ0z1ApYjJo). Fully implements all 5 Harness Golden Principles.

## How It Works

### Rule Injection (active from session start)

The native rule set in `rules/claude-rules/` is installed to Claude Code's native rules system (`~/.claude/rules/vibeguard/`), directly influencing AI reasoning. Plus a 7-layer constraint index injected into `~/.claude/CLAUDE.md`:

| Layer | Constraint | Effect |
|-------|-----------|--------|
| L1 | Search before create | Must search for existing implementations before creating new files |
| L2 | Naming conventions | `snake_case` internally, `camelCase` at API boundaries, no aliases |
| L3 | Quality baseline | No silent exception swallowing, no `Any` types in public methods |
| L4 | Data integrity | No data = show blank, no hardcoding, no inventing APIs |
| L5 | Minimal changes | Only do what was asked, no unsolicited "improvements" |
| L6 | Process gates | Large changes require preflight, structured planning, and verification |
| L7 | Commit discipline | No AI markers, no force push, no secrets |

Rules use **negative constraints** ("X does not exist") to implicitly guide AI, which is often more effective than positive descriptions.

Canonical references for this contract:
- Install/runtime contract: `schemas/install-modules.json`
- Native rule source: `rules/claude-rules/`
- Public summary of current rule surface: `docs/rule-reference.md`

### Hooks — Real-Time Interception

Most hooks trigger automatically during AI operations. `skills-loader` remains an optional manual hook. Codex deploys native Bash/apply_patch/PermissionRequest/PostToolUse/Stop hooks; read-only exploration hooks remain Claude Code or app-server-wrapper only:

| Scenario | Hook | Result |
|----------|------|--------|
| AI creates new `.py/.ts/.rs/.go/.js` file | `pre-write-guard` | **Warn by default** — search-first reminder; set `VIBEGUARD_WRITE_MODE=block` or `write_mode=block` to hard-block |
| AI creates or edits production source above 800 lines | `pre-write-guard`, `pre-edit-guard` | **Block** — split the file before writing or patching |
| AI runs `git push --force`, `rm -rf`, `reset --hard` | `pre-bash-guard` | **Block** — suggests safe alternatives |
| AI edits non-existent file | `pre-edit-guard` | **Block** — must Read file first |
| AI adds `unwrap()`, hardcoded paths | `post-edit-guard` | **Warn** — with fix instructions |
| AI adds `console.log` / `print()` debug statements | `post-edit-guard` | **Warn** — use logger instead |
| AI creates duplicate definitions after a new file write | `post-write-guard` | **Warn** — detect duplicate symbols and same-name files |
| AI keeps reading/searching without acting | `analysis-paralysis-guard` | **Escalate** — force a concrete next step or blocker report |
| AI edits code in `full` / `strict` profile | `post-build-check` | **Warn** — run language-appropriate build check |
| `git commit` | `pre-commit-guard` | **Block** — quality + build checks (staged files only), 10s timeout |
| AI tries to finish with unverified changes | `stop-guard` | **Gate** — complete verification first |
| Session ends | `learn-evaluator` | **Evaluate** — collect metrics and detect correction signals |

U-16 file-size enforcement applies to non-test source files with `.rs`, `.ts`, `.tsx`, `.js`, `.jsx`, `.py`, or `.go` extensions. For Codex, `apply_patch Add File` and `apply_patch Update File` are both normalized before the file hook runs, so edits that would take a production source file past the 800-line limit are denied before mutation.

### Static Guards — Run Anytime

Representative standalone checks you can run on any project. The complete inventory lives in [docs/rule-reference.md](docs/rule-reference.md).

```bash
# Universal
bash ~/vibeguard/guards/universal/check_code_slop.sh /path/to/project     # AI code slop
python3 ~/vibeguard/guards/universal/check_dependency_layers.py /path      # dependency direction
python3 ~/vibeguard/guards/universal/check_circular_deps.py /path          # circular deps
bash ~/vibeguard/guards/universal/check_test_integrity.sh /path            # test shadowing / integrity issues
bash ~/vibeguard/guards/universal/check_dependency_changes.sh --base origin/main --head HEAD  # SEC-11 dependency review
bash ~/vibeguard/guards/universal/check_test_weakening.sh --base origin/main --head HEAD      # SEC-11/W-12 test weakening

# Rust
bash ~/vibeguard/guards/rust/check_unwrap_in_prod.sh /path                 # unwrap/expect in prod
bash ~/vibeguard/guards/rust/check_nested_locks.sh /path                   # deadlock risk
bash ~/vibeguard/guards/rust/check_declaration_execution_gap.sh /path      # declared but not wired
bash ~/vibeguard/guards/rust/check_duplicate_types.sh /path                # duplicate type definitions
bash ~/vibeguard/guards/rust/check_semantic_effect.sh /path                # semantic side effects
bash ~/vibeguard/guards/rust/check_single_source_of_truth.sh /path         # single source of truth
bash ~/vibeguard/guards/rust/check_taste_invariants.sh /path               # taste/style invariants
bash ~/vibeguard/guards/rust/check_workspace_consistency.sh /path          # workspace dep consistency

# Go
bash ~/vibeguard/guards/go/check_error_handling.sh /path                   # unchecked errors
bash ~/vibeguard/guards/go/check_goroutine_leak.sh /path                   # goroutine leaks
bash ~/vibeguard/guards/go/check_defer_in_loop.sh /path                    # defer in loop

# TypeScript
bash ~/vibeguard/guards/typescript/check_any_abuse.sh /path                # any type abuse
bash ~/vibeguard/guards/typescript/check_console_residual.sh /path         # console.log residue
bash ~/vibeguard/guards/typescript/check_component_duplication.sh /path    # duplicated component files
bash ~/vibeguard/guards/typescript/check_duplicate_constants.sh /path      # repeated constant definitions

# Python
python3 ~/vibeguard/guards/python/check_duplicates.py /path                # duplicate functions/classes/protocols
python3 ~/vibeguard/guards/python/check_naming_convention.py /path         # camelCase mix
python3 ~/vibeguard/guards/python/check_dead_shims.py /path                # dead re-export shims
```

## Slash Commands

12 custom commands covering the full development lifecycle. Shortcuts: `/vg:pf` `/vg:gc` `/vg:ck` `/vg:lrn`.

| Command | Purpose |
|---------|---------|
| `/vibeguard:preflight` | Generate constraint set before changes |
| `/vibeguard:check` | Full guard scan + compliance report |
| `/vibeguard:review` | Structured code review (security → logic → quality → perf) |
| `/vibeguard:cross-review` | Dual-model adversarial review (Claude + Codex) |
| `/vibeguard:build-fix` | Build error resolution |
| `/vibeguard:learn` | Generate guard rules from errors / extract Skills from discoveries |
| `/vibeguard:skill-validate` | Gate proposed skills with repair/regression evidence before acceptance |
| `/vibeguard:interview` | Deep requirements interview → SPEC.md |
| `/vibeguard:exec-plan` | Long-running task execution plan, cross-session resume |
| `/vibeguard:live-truth` | Fresh evidence gates for latest, PR-ready, merged, running, deployed, and published claims |
| `/vibeguard:gc` | Garbage collection (logs + worktrees + rule budget + code slop scan) |
| `/vibeguard:stats` | Hook trigger statistics |

**Routing Contract**

Workflow routing is defined once in [workflows/references/routing-contract.md](workflows/references/routing-contract.md).

- Precedence: `user_override` → `risk/destructive gate` → `ambiguity gate` → `readiness classifier` → `execution/delegation lane`
- Readiness outputs: `execute_direct`, `plan_first`, `clarify_first`
- Planning surfaces emit the shared handoff fields: `mode`, `artifacts`, `runtime_pinning_snapshot`, `verification_owner`, `stop_conditions`, `lane_map`
- Delegated multi-agent work uses [workflows/references/delegation-contract.md](workflows/references/delegation-contract.md) for child-agent assignments, parallelism limits, and single-owner reintegration

Use workflow prompts and dispatcher guidance as consumers of that contract, not as independent routing sources.

## Multi-Agent Dispatch

14 built-in agent prompts (13 specialists + 1 dispatcher) with automatic routing:

| Agent | Purpose |
|-------|---------|
| `dispatcher` | **Auto-route** — analyzes task type and routes to the best agent |
| `planner` / `architect` | Requirements analysis and system design |
| `tdd-guide` | RED → GREEN → IMPROVE test-driven development |
| `code-reviewer` / `security-reviewer` | Layered code review and OWASP Top 10 |
| `build-error-resolver` | Build error diagnosis and fix |
| `go-reviewer` / `python-reviewer` / `database-reviewer` | Language-specific review |
| `refactor-cleaner` / `doc-updater` / `e2e-runner` | Refactoring, docs, and E2E tests |

## Observability

```bash
bash ~/vibeguard/scripts/quality-grader.sh              # Quality grade (A/B/C/D)
bash ~/vibeguard/scripts/stats.sh                       # Hook trigger stats (7 days)
bash ~/vibeguard/scripts/hook-health.sh 24              # Hook health snapshot
bash ~/vibeguard/scripts/doctors/codex-doctor.sh        # Codex install + hook capability diagnosis
bash ~/vibeguard/scripts/metrics/metrics-exporter.sh    # Prometheus metrics export
bash ~/vibeguard/scripts/verify/doc-freshness-check.sh  # Rule-guard coverage check
```

Doctors are read-only diagnosis wrappers over the existing defense system. They summarize installation state, capability gaps, noisy hooks, recent events, and repair commands; hooks and guards remain the enforcement layer that blocks or warns during real tool execution.

Hook latency is also a product contract. See [Hook Latency Contract](docs/reference/hook-latency-contract.md) for per-hook P95 budgets, hotspot attribution, and the static gates that block expensive hook patterns.

## Learning System

Closed-loop learning evolves defenses from mistakes:

**Mode A — Defensive**

```text
/vibeguard:learn <error description>
```

Analyzes root cause (5-Why) → generates a new guard/hook/rule → verifies detection → the same class of error should not recur.

**Mode B — Accumulative**

```text
/vibeguard:learn extract
```

Extracts non-obvious solutions as structured Skill files for future reuse.

## Installation

### Profiles and languages

```bash
# Profiles
bash ~/vibeguard/setup.sh                              # Install (default: core profile)
bash ~/vibeguard/setup.sh --profile minimal           # Minimal: pre-hooks only (lightweight)
bash ~/vibeguard/setup.sh --profile full              # Full: adds Stop Gate + Build Check + learning
bash ~/vibeguard/setup.sh --profile strict            # Strict: same hook set as full, for stricter runtime policy

# Language selection (only install rules/guards for specified languages)
bash ~/vibeguard/setup.sh --languages rust,python
bash ~/vibeguard/setup.sh --profile full --languages rust,typescript

# Verify / Uninstall
bash ~/vibeguard/setup.sh --check                     # Verify installation
bash ~/vibeguard/setup.sh --check --quiet             # Show only problems + rollup
bash ~/vibeguard/setup.sh --check --json              # Machine-readable JSON for CI
bash ~/vibeguard/setup.sh --check --strict            # Exit 1/2 on warn/broken
bash ~/vibeguard/setup.sh --clean                     # Uninstall
```

`--check` reports a structured rollup (OK / INFO / WARN / FAIL / BROKEN / MISSING)
plus a final `Verdict` line of `HEALTHY`, `DEGRADED`, or `BROKEN`. The default mode
always exits 0 for backwards compatibility — add `--strict` (or use `--json`,
which implies it) to make CI fail when the install is broken.

| Profile | Hooks Installed | Use Case |
|---------|----------------|----------|
| `minimal` | pre-write, pre-edit, pre-bash | Lightweight — only critical interception |
| `core` (default) | minimal + post-edit, post-write, analysis-paralysis | Standard development |
| `full` | core + stop-guard, learn-evaluator, post-build-check | Full defense + learning |
| `strict` | same hook set as full | Maximum enforcement |

`setup.sh` also prepares the shared pre-commit wrapper at `~/.vibeguard/pre-commit` and installs this repository's git pre-commit hook during setup. To attach the wrapper to another repository, use `scripts/project-init.sh` or that repository's own install step.

### Codex Integration

VibeGuard deploys hooks and skills to both Claude Code and Codex CLI.

Hooks live in `~/.codex/hooks.json` (requires `[features].hooks = true` in `config.toml`):

| Event | Hook | Function |
|-------|------|----------|
| `PreToolUse(Bash)` | `pre-bash-guard.sh` | Dangerous command interception + package manager correction |
| `PermissionRequest(Bash)` | `pre-bash-guard.sh` | Fail-closed approval gate for dangerous commands |
| `PreToolUse(Edit/Write via apply_patch)` | `pre-edit-guard.sh`, `pre-write-guard.sh` | File existence and search-first gates before patching |
| `PermissionRequest(Edit/Write via apply_patch)` | `pre-edit-guard.sh`, `pre-write-guard.sh` | Fail-closed approval gate before privileged patching |
| `PostToolUse(Bash/apply_patch)` | `post-build-check.sh` | Build failure detection after commands or patches |
| `PostToolUse(Edit/Write via apply_patch)` | `post-edit-guard.sh`, `post-write-guard.sh` | Post-patch quality and duplicate checks |
| `Stop` | `stop-guard.sh` | Uncommitted changes gate |
| `Stop` | `learn-evaluator.sh` | Session metrics collection |

This is the default enforcement layer. It talks to Codex through native hooks
and does not wrap or replace the Codex server. Codex has no native `Read`,
`Glob`, or `Grep` hook surface, so `analysis-paralysis` remains Claude Code only.

Codex hook command names are namespaced as `vibeguard-*.sh` to avoid collisions with other toolchains sharing `~/.codex/hooks.json`. Output format differences are handled by the `run-hook-codex.sh` wrapper (Claude Code `decision:block` -> Codex deny payloads). Codex sends `apply_patch` as a patch command, so the wrapper normalizes that payload into Edit/Write-shaped inputs before calling the existing VibeGuard file hooks. For `Update File` patches, the wrapper also passes the line delta so `pre-edit-guard.sh` can enforce U-16 before Codex mutates the file. When a hook suggests `updatedInput`, the Codex CLI wrapper cannot apply it automatically, so VibeGuard emits an explicit note with the suggested replacement command instead of silently dropping it.

**MCP server status:** the legacy `mcp-server/` prototype is not installed by `setup.sh` and is not part of the supported runtime surface. Supported integrations are the Claude Code hooks, native Codex hooks, and the optional app-server wrapper below; any future MCP reintroduction must go through an explicit install path and hash/audit baseline.

**App-server wrapper** (Symphony-style orchestrators):

```bash
~/.vibeguard/installed/bin/vibeguard-runtime codex-app-server-wrapper --repo-dir ~/vibeguard --codex-command "codex app-server"
```

- `--strategy vibeguard` (default): applies strategy-based command, file-change, analysis-loop, and post-turn gates externally
- `--strategy noop`: pure pass-through for debugging
- Runtime: Rust-only via `vibeguard-runtime`; there is no Python app-server wrapper fallback.
- App-server wrapper is optional and mainly for external orchestrators that already speak `codex app-server`
- App-server wrapper scope today: Bash approval interception; `applyPatchApproval` / `item/fileChange/requestApproval` file-change guards mapped to `pre-edit`, `pre-write`, `post-edit`, and `post-write`; proxy-native `analysis-paralysis` warnings for read-only command streaks; post-turn stop/build feedback with explicit `thread/session/turn` propagation.
- Guard mode: `VIBEGUARD_CODEX_GUARD_MODE=guarded` by default. `decline` / `denied` tells Codex to continue the turn with a warning; `strict` upgrades file changes to `cancel` / `abort`; `advisory` emits warnings without blocking.
- Default local protection should use native Codex hooks in `~/.codex/hooks.json`
- Still unsupported on native Codex path: `Read`/`Glob`/`Grep` hooks such as `analysis-paralysis`

### Use with any project

| Tool | How |
|------|-----|
| **OpenAI Codex** | `cp ~/vibeguard/templates/AGENTS.md ./AGENTS.md` + `bash ~/vibeguard/setup.sh` (installs skills + Codex hooks) |
| **Any project (rules only)** | `cp ~/vibeguard/docs/CLAUDE.md.example ./CLAUDE.md` |

### Project Bootstrap

Bootstrap another repository with project-specific guidance and the pre-commit wrapper:

```bash
bash ~/vibeguard/scripts/project-init.sh /path/to/project
```

### Local Contract Gate (contributors)

Run stable contract checks locally before pushing, or wire them as a pre-commit hook:

```bash
bash scripts/local-contract-check.sh          # run the full local gate
bash scripts/install-pre-commit-hook.sh       # install as git pre-commit hook
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local-vs-CI split and the `--quick` flag.

### Custom Rules

Add your own rules to `~/.vibeguard/user-rules/`. Any `.md` files placed there are automatically installed to `~/.claude/rules/vibeguard/custom/` on the next setup run. Format: standard Claude Code rule files with YAML frontmatter.

## Design Principles

| Principle | From | Implementation |
|-----------|------|----------------|
| Automation over documentation | Harness #3 | Hooks + guard scripts enforce mechanically |
| Error messages = fix instructions | Harness #3 | Every interception tells AI how to fix, not just what's wrong |
| Maps not manuals | Harness #5 | 7-layer index + negative constraints + lazy loading |
| Failure → capability | Harness #2 | Mistake → learn → new guard → never again |
| If agent can't see it, it doesn't exist | Harness #1 | All decisions written to repo (`CLAUDE.md` / ExecPlan / logs) |
| Give agent eyes | Harness #4 | Observability stack (logs + metrics + alerts) |

## Known Issues

Guard scripts rely heavily on pattern matching (grep/awk or lightweight AST helpers), which means false positives can still happen in some scenarios.

- [Known False Positives](docs/known-issues/false-positives.md) — identified false positive scenarios, fixes, and lessons learned

Key lessons:

- **grep is not an AST parser** — nested scopes and multi-block structures need language-aware tools
- **Guard fix messages are consumed by AI agents** — an imprecise fix hint can itself trigger unnecessary edits
- **Project type awareness matters** — CLI/Web/MCP/Library codebases may need different acceptable patterns for the same language rule

## Documentation

| Doc | Purpose |
|-----|---------|
| [docs/README_CN.md](docs/README_CN.md) | Chinese overview and setup guide |
| [docs/rule-reference.md](docs/rule-reference.md) | Rule layers, guard coverage, and language-specific checks |
| [docs/CLAUDE.md.example](docs/CLAUDE.md.example) | Project-level CLAUDE template without installing hooks |
| [docs/linux-setup.md](docs/linux-setup.md) | Linux-specific setup notes |
| [docs/known-issues/false-positives.md](docs/known-issues/false-positives.md) | Known guard false positives and mitigation notes |
| [docs/assets/README.md](docs/assets/README.md) | Demo recording script and assets |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contributor workflow, validation commands, and commit protocol |

## References

- [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/)
- [Stripe Minions](https://www.youtube.com/watch?v=bZ0z1ApYjJo)
- [Anthropic: Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)

---

[Chinese Documentation →](docs/README_CN.md)
