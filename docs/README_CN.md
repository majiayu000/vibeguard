# VibeGuard

[![CI](https://github.com/majiayu000/vibeguard/actions/workflows/ci.yml/badge.svg)](https://github.com/majiayu000/vibeguard/actions/workflows/ci.yml)

[English](README.md)

Let AI no longer make up code when writing code.

When writing code with Claude Code / Codex, AI often fabricates APIs out of thin air, reinvents the wheel, hardcodes fake data, and over-designs. VibeGuard blocks these problems from the source through three lines of defense: rule injection + real-time interception + static scanning.

The design is inspired by [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/) and [Stripe Minions](https://www.youtube.com/watch?v=bZ0z1ApYjJo), which fully implements the 5 Golden Principles of Harness.

## Install

```bash
git clone https://github.com/majiayu000/vibeguard.git ~/vibeguard
bash ~/vibeguard/setup.sh #Default core (recommended)
bash ~/vibeguard/setup.sh --profile full # full: additionally enable Stop Gate + Post-Build-Check + Pre-Commit Hook
```

After the installation is complete, opening a new Claude Code session will take effect. Run `bash ~/vibeguard/setup.sh --check` to verify the installation status.

## What does it do

Once installed, VibeGuard works automatically on three levels:

### 1. Rule injection (takes effect when a session is opened)

VibeGuard injects rules via two paths:

**Path 1: Native rules (`~/.claude/rules/vibeguard/`)** — 90+ rules loaded through Claude Code’s native rules mechanism, supporting `paths` scope (language-specific rules are only activated when matching files), directly affecting the AI inference layer.

**Path 2: CLAUDE.md injection (`~/.claude/CLAUDE.md`)** — Seven-level constraint index appended to user-level global configuration. When Claude Code starts, it loads all levels of CLAUDE.md and takes effect superimposed:

```
Enterprise/Library/Application Support/ClaudeCode/CLAUDE.md ← IT Deployment
User level ~/.claude/CLAUDE.md ← VibeGuard rules index here
Project-level ./CLAUDE.md or ./.claude/CLAUDE.md ← Project-specific constraints
Local ./CLAUDE.local.md ← Personal configuration (automatic gitignore)
Subdirectory ./subdir/CLAUDE.md ← Lazy loading, loaded only when accessed
```

All levels are concatenate into the AI context, and **VibeGuard global rules and project rules naturally coexist**. A project's CLAUDE.md can be supplemented with project-specific constraints (such as "use pnpm instead of npm"), and VibeGuard continues to protect the bottom line. If instructions conflict, Claude tends to adhere to the more specific one.

Seven levels of constraints:

| Layers | Constraints | Effects |
|----|------|------|
| L1 | Search first and then write | Before creating a new file/class/function, you must first search for existing implementations to prevent reinventing the wheel |
| L2 | Naming constraints | Python internal snake_case, API boundary camelCase, no aliasing allowed |
| L3 | Quality baseline | Silent swallowing of exceptions is prohibited, and `Any` type is prohibited in public methods |
| L4 | Data authenticity | Display blank if there is no data, no hard coding, no inventing APIs that do not exist |
| L5 | Minimal changes | Just do what is asked, no additional "improvements" |
| L6 | Process Constraints | Preflight for major changes first, then check after completion |
| L7 | Submission discipline | Ban AI tags, force push, backward compatibility |

Rules implicitly guide the AI using negative constraints ("X does not exist"), which are more effective than positive descriptions (Golden Principle #5: Give a map but not a manual).

### 2. Hooks real-time interception (automatically triggered when writing code)

Most Hooks do not need to be run manually and are automatically intercepted during AI operations; `skills-loader` is a reserved optional script:

| Scenario | Trigger | Result |
|------|------|------|
| AI wants to create a new `.py/.ts/.rs/.go/.js` file | `pre-write-guard` | **Interception** — must first search whether there is a similar implementation |
| AI wants to execute `git push --force`, `rm -rf`, `reset --hard` | `pre-bash-guard` | **Interception** - Gives a safe alternative (subcommand aware, does not block `git add -f` by mistake) |
| AI wants to edit a file that does not exist | `pre-edit-guard` | **Intercept** — Read first to confirm the file content |
| Added `unwrap()` and hard-coded path after AI editing | `post-edit-guard` | **Warning** — Give specific repair methods |
| Added `console.log` / `print()` debugging statements after AI editing | `post-edit-guard` | **Warning** — Prompt to use logger |
| Duplicate definitions or files with the same name exist after AI creates a new file | `post-write-guard` | **Warning** — Detect duplicate definitions |
| AI post-edit build check failed (`full` profile) | `post-build-check` | **Warning** — Automatically run the corresponding language build check |
| Manually enable when needed | `skills-loader` | **Optional** — Output Skill/learning prompts when reading for the first time, not enabled by default |
| When `git commit` | `pre-commit-guard` | **Interception** — quality check + build check, 10s timeout hard limit |
| AI wants to end but there are unverified source code changes (`full` profile) | `stop-guard` | **Gate guard** — remind to complete the verification before ending |
| At the end of the session | `learn-evaluator` | **Evaluate** — Collect metrics + detect corrective signals, recommend when there are signals /learn |

Each Hook execution automatically records the time taken (`duration_ms`) and agent type to the log to support performance monitoring.

## Order

10 custom commands covering the entire life cycle from requirements to operation and maintenance:

| Command | Purpose |
|------|------|
| `/vibeguard:interview` | In-depth interview on large functional requirements, output SPEC.md |
| `/vibeguard:exec-plan` | Long-term task execution plan, supports cross-session recovery |
| `/vibeguard:preflight` | Generate a constraint set before modification to prevent problems from the source |
| `/vibeguard:check` | Full guard scan + compliance report |
| `/vibeguard:review` | Structured code review (security → logic → quality → performance) |
| `/vibeguard:cross-review` | Dual model adversarial review (Claude + Codex) |
| `/vibeguard:build-fix` | Build error fix |
| `/vibeguard:learn` | Generate guard rules from errors / Extract Skills from findings |
| `/vibeguard:gc` | Garbage collection (log archiving + worktree cleaning + code garbage scanning) |
| `/vibeguard:stats` | Hook trigger statistics |

Shortcut aliases: `/vg:pf`(preflight) `/vg:gc`(gc) `/vg:ck`(check) `/vg:lrn`(learn)

### Recommended workflow

```
interview → exec-plan → preflight → coding → check → review → learn → stats
```

### Complexity routing

Automatically select process depth based on change size:

| Scale | Process |
|------|------|
| 1-2 File | Direct implementation |
| 3-5 File | `/vibeguard:preflight` → constraint set → implementation |
| 6+ Documentation | `/vibeguard:interview` → SPEC → `/vibeguard:preflight` → Implementation |

## Harness Engineering — Five Golden Principles implementation

VibeGuard fully implements the 5 Golden Principles of OpenAI Harness Engineering:

### 1. What the Agent cannot see does not exist.

All decisions are written into the warehouse, not left in Slack or in your head:

- CLAUDE.md seven-layer rules - automatically loaded when AI starts
- ExecPlan Decision Log — All decisions on long-term tasks are recorded in documents
- preflight constraint set - constraints before coding are solidified in document form

### 2. Ask "What abilities are missing" instead of "Why did you fail?"

Make up for your abilities when encountering problems, instead of writing a better prompt:

- `/vibeguard:learn` — Automatically generate new guard rules from errors, and accumulate incremental capabilities
- learn-evaluator Hook — Evaluate at the end of the session whether there is any extractable experience
- Skill system - the extracted experience is saved as Skill and automatically reused in the future

### 3. Mechanical Execution > Document Description

If you can use a script to detect it, write a script instead of relying on AI awareness:

- Pre/Post Hooks — real-time interception, cannot be bypassed
- Dependency layer Linter (`check_dependency_layers.py`) — detects cross-layer violations, the error message **contains repair instructions**
- Circular dependency detection (`check_circular_deps.py`) — Build module dependency graph and detect loops
- Code garbage scan (`check_code_slop.sh`) — detects empty catches, legacy debugging, expired TODOs, dead code

### 4. Give Agent a pair of eyes

The observable stack allows AI to discover problems from data:

- `hooks/log.sh` — records timestamp, time taken (ms), agent type, session ID for each operation
- `scripts/metrics/metrics-exporter.sh` — export Prometheus format metrics, support Pushgateway
- `templates/alerting-rules.yaml` — 4 alerting rules (violation rate, Hook timeout, inactivity, Block sudden increase)
- `/vibeguard:stats` — Hook triggers statistical analysis

### 5. Give a map but not a manual

Progressive disclosure, streamlined indexing, and detailed rules loaded on demand:

- `vibeguard-rules.md` is controlled at line 32 - only index is placed, detailed rules are in the `rules/` directory
- Negative constraints - "ORM does not exist", "alias does not exist" are more effective than "Please use X"
- Path scope rules - different directories automatically load different constraints to reduce irrelevant tokens
- `templates/AGENTS.md` — provides equivalent constraint files for OpenAI Codex users

## ExecPlan — Long-term task execution plan

Large tasks that span sessions require self-contained execution documents that can resume execution in new sessions by themselves:

```
/vibeguard:exec-plan init [spec path] # Generate ExecPlan from SPEC
/vibeguard:exec-plan status <path> # Check the progress
/vibeguard:exec-plan update <path> #Append decision/discovery/completion status
```

ExecPlan 8-section structure: Purpose → Progress → Context → Plan of Work → Concrete Steps → Validation → Idempotence → Execution Journal

Complete pipeline: `interview → SPEC → exec-plan → preflight → execution → exec-plan update`

## Garbage collection (GC)

Prevent AI code garbage and runtime garbage accumulation (refer to Harness GC Agent):

```
/vibeguard:gc
```

| Module | Function |
|------|------|
| `gc-logs.sh` | events.jsonl Over 10MB Archived monthly (gzip), retained for 3 months |
| `gc-worktrees.sh` | Delete worktrees that have been inactive for >7 days, only warn if there are unmerged changes |
| `check_code_slop.sh` | 5 types of AI garbage: empty catch, debug code, expired TODO, dead code, overlong file |

Can also be run alone:

```bash
bash ~/vibeguard/scripts/gc/gc-logs.sh --dry-run
bash ~/vibeguard/scripts/gc/gc-worktrees.sh --days 14
bash ~/vibeguard/guards/universal/check_code_slop.sh /path/to/project
```

## Dependency layer Linter

Enforce `Types → Config → Repo → Service → Runtime → UI` one-way dependency:

```bash
# Detect cross-layer violations
python3 ~/vibeguard/guards/universal/check_dependency_layers.py /path/to/project

# Detect circular dependencies
python3 ~/vibeguard/guards/universal/check_circular_deps.py /path/to/project
```

You need to place `.vibeguard-architecture.yaml` in the project root directory to define the hierarchical structure. template:

```bash
cp ~/vibeguard/templates/vibeguard-architecture.yaml .vibeguard-architecture.yaml
```

Output an error message containing repair instructions when a violation occurs (Golden Principle #3).

## Multi-Agent automatic scheduling

14 special agents + 1 dispatcher automatic routing:

| Agent | What to do |
|-------|--------|
| `dispatcher` | **Automatic dispatch** — analyze task types and route to the most appropriate agent |
| `planner` | Requirements analysis, task decomposition |
| `architect` | Technical solutions, architectural design |
| `tdd-guide` | RED → GREEN → IMPROVE test driver |
| `code-reviewer` | Hierarchical code review |
| `security-reviewer` | OWASP Top 10 Security Review |
| `build-error-resolver` | Build error fix |
| `e2e-runner` | End-to-end testing |
| `refactor-cleaner` | Refactor, eliminate duplication |
| `doc-updater` | Synchronize documents after code changes |
| `go-reviewer` / `go-build-resolver` | Go-specific |
| `python-reviewer` | Python specialization |
| `database-reviewer` | SQL injection, N+1, transactions |

Dispatcher automatic scheduling rules:
- Build errors → `build-error-resolver`
- Test file changes → `tdd-guide`
- Database migration → `database-reviewer`
- Security related → `security-reviewer`
- 5+ file refactoring → `refactor-cleaner`

Inference budget sandwich (refer to Harness): opus for planning → sonnet for execution → opus for verification.

## Observable stack

```bash
# Quality grade score (A/B/C/D, dynamic recommended GC frequency)
bash ~/vibeguard/scripts/quality-grader.sh # Last 30 days
bash ~/vibeguard/scripts/quality-grader.sh --json # JSON format

# Document freshness (rules-guard coverage detection)
bash ~/vibeguard/scripts/verify/doc-freshness-check.sh

# Ability evolution log (Guard/Rule/Skill change timeline)
bash ~/vibeguard/scripts/log-capability-change.sh --since 2026-02-01

# Prometheus indicator export
bash ~/vibeguard/scripts/metrics/metrics-exporter.sh # Output to stdout
bash ~/vibeguard/scripts/metrics/metrics-exporter.sh --push <gateway> # Push to Pushgateway
bash ~/vibeguard/scripts/metrics/metrics-exporter.sh --file /path/to.prom # Write textfile

# Log statistics
bash ~/vibeguard/scripts/stats.sh # Last 7 days
bash ~/vibeguard/scripts/stats.sh 30 # Last 30 days
```

Indicators include: `hook_trigger_total`, `tool_total`, `hook_duration_seconds`, `guard_violation_total`.

Quality scoring formula: `security × 0.4 + stability × 0.3 + coverage × 0.2 + performance × 0.1`, grade A(≥90)/B(70-89)/C(50-69)/D(<50) corresponding to GC frequency 7 days/3 days/1 day/real time.

The alerting rule template is in `templates/alerting-rules.yaml`, covering four scenarios: excessive violation rate, Hook timeout, inactivity, and block sudden increase.

## Learning system

Dual-mode closed-loop learning, automatically evolving from mistakes:

### Mode A — Defensive (Learn from Mistakes)

```
/vibeguard:learn <error description>
```

Analyze the root cause of the error (5-Why) → Generate a new guard script/Hook/rule → Verify that the original error can be detected → Similar errors will no longer occur.

### Mode B — Accumulation (Extract Skill from discovery)

```
/vibeguard:learn extract
```

When non-obvious solutions are found in the session, they are extracted into structured skill files and automatically reused when similar problems are encountered in the future.

Quality gating: reusable + non-trivial + specific + verified, only save if all are met.

### Automatic evaluation

`learn-evaluator.sh` automatically evaluates whether there is experience worth extracting at the end of the session, reminding the user to run learn.

## Guard script

Static checks that can be run individually:

**GENERAL**
```bash
bash ~/vibeguard/guards/universal/check_code_slop.sh /path/to/project # AI code garbage
python3 ~/vibeguard/guards/universal/check_dependency_layers.py /path/to/project # Dependency layer direction
python3 ~/vibeguard/guards/universal/check_circular_deps.py /path/to/project # Circular dependencies
```

**Rust**
```bash
bash ~/vibeguard/guards/rust/check_unwrap_in_prod.sh /path/to/project
bash ~/vibeguard/guards/rust/check_duplicate_types.sh /path/to/project
bash ~/vibeguard/guards/rust/check_nested_locks.sh /path/to/project
bash ~/vibeguard/guards/rust/check_workspace_consistency.sh /path/to/project
bash ~/vibeguard/guards/rust/check_single_source_of_truth.sh /path/to/project
bash ~/vibeguard/guards/rust/check_semantic_effect.sh /path/to/project
bash ~/vibeguard/guards/rust/check_taste_invariants.sh /path/to/project # Harness code taste
bash ~/vibeguard/guards/rust/check_declaration_execution_gap.sh /path/to/project
```

**Go**
```bash
bash ~/vibeguard/guards/go/check_error_handling.sh /path/to/project # GO-01: unchecked error
bash ~/vibeguard/guards/go/check_goroutine_leak.sh /path/to/project # GO-02: goroutine leak
bash ~/vibeguard/guards/go/check_defer_in_loop.sh /path/to/project        # GO-08: defer-in-loop
```

**Python**
```bash
python3 ~/vibeguard/guards/python/check_duplicates.py /path/to/project
python3 ~/vibeguard/guards/python/check_naming_convention.py /path/to/project
```

## Rule system

### Guard rules (`rules/`)

Checking rule definition for guard script:

| Documentation | Content |
|------|------|
| `universal.md` | U-01 ~ U-24 Universal Rules |
| `security.md` | SEC-01 ~ SEC-10 Security Rules |
| `typescript.md` | TS-01 ~ TS-12 |
| `python.md` | PY-01 ~ PY-12 |
| `go.md` | GO-01 ~ GO-12 |
| `rust.md` | Rust-specific rules |

### Native rules (`rules/claude-rules/` → `~/.claude/rules/vibeguard/`)

90+ rules are loaded through Claude Code’s native rules mechanism and take effect in the AI reasoning layer (not just script interception):

| Directory | Content | Scope |
|------|------|--------|
| `common/coding-style.md` | U-01 ~ U-26 common constraints (including U-25 build failure repair priority, U-26 declaration-execution integrity) | Global |
| `common/data-consistency.md` | U-11 ~ U-14 cross-entry data consistency | Global |
| `common/security.md` | SEC-01 ~ SEC-10 Security Rules | Global |
| `common/workflow.md` | W-01 ~ W-05 workflow constraints (debugging protocol, continuous failure fallback, assertion after verification) | Global |
| `rust/quality.md` | Rust-specific | `**/*.rs, **/Cargo.toml` |
| `golang/quality.md` | Go-specific | `**/*.go, **/go.mod` |
| `typescript/quality.md` | TypeScript-specific | `**/*.ts, **/*.tsx` |
| `python/quality.md` | Python specialization | `**/*.py` |

> **Note**: There is a bug in the YAML `paths` array parsing of Claude Code user-level `~/.claude/rules/` ([#21858](https://github.com/anthropics/claude-code/issues/21858)), which must be in CSV single-line format (such as `paths: "**/*.rs,**/Cargo.toml"`).

### Inline exclusion

Guard scripts support `// vibeguard:ignore` inline comments to skip single-line detection:

```go
result := dangerousOp() // vibeguard:ignore
```

Currently supported: RS-03 (unwrap), GO-01 (error handling), GO-02 (goroutine leak), TS-01 (any abuse).

## manage

```bash
bash ~/vibeguard/setup.sh # Install/update (default core)
bash ~/vibeguard/setup.sh --profile full # Switch to full profile
bash ~/vibeguard/setup.sh --check # Check installation status
bash ~/vibeguard/setup.sh --clean # Uninstall
```

## Warehouse structure

```
vibeguard/
├── setup.sh # One-click installation/uninstallation/checking
├── agents/ # 14 special agents (including dispatcher automatic scheduling)
├── hooks/ # Real-time interception script
│ ├── log.sh # Shared log (duration_ms + agent type)
│ ├── run-hook.sh # Hook execution entry
│ ├── pre-write-guard.sh # New file interception
│ ├── pre-bash-guard.sh # Dangerous command interception (subcommand awareness)
│ ├── pre-edit-guard.sh # Anti-hallucination editing
│ ├── pre-commit-guard.sh # Automatic guard before git commit (10s timeout)
│ ├── post-edit-guard.sh # Quality warning (including churn detection)
│ ├── post-write-guard.sh # New file duplication detection
│ ├── post-build-check.sh # Build check (full profile)
│ ├── skills-loader.sh # Optional first-time Read Skill/learning prompt script (not enabled by default)
│ ├── stop-guard.sh # Verify access control before completion
│ └── learn-evaluator.sh # End-of-session learning evaluation
├── guards/ # Static inspection script (supports // vibeguard:ignore inline exclusion)
│ ├── universal/ # Universal guard (code garbage, dependency layer, circular dependency)
│ ├── rust/ # Rust guards (including Taste Invariants, declaration-execution gap detection)
│ ├── go/ # Go guard (error check, goroutine leak, defer-in-loop)
│ ├── python/ # Python guard
│ └── typescript/ # TypeScript guard
├── .claude/commands/vibeguard/ # 10 custom commands
├── .claude/commands/vg/ # Command alias (pf/gc/ck/lrn)
├── templates/ # template
│ ├── project-rules/ # Path scope rules
│ ├── vibeguard-architecture.yaml #Dependency layer definition
│ ├── alerting-rules.yaml # Prometheus alerting rules
│ └── AGENTS.md # OpenAI Codex Equivalent Constraints
├── workflows/plan-flow/ # Workflow + ExecPlan template
├── claude-md/vibeguard-rules.md # Index of rules injected into CLAUDE.md
├── rules/ # Rule definition file
│ ├── universal.md # U-01 ~ U-24 Universal rules
│   ├── security.md                       #   SEC-01 ~ SEC-10
│ ├── rust.md / go.md / ... # Language-specific rules
│ └── claude-rules/ # Native rules (deployed to ~/.claude/rules/vibeguard/)
│       ├── common/                       #     coding-style(U-01~U-26) + data-consistency + security + workflow(W-01~W-05)
│ ├── rust/ golang/ typescript/ python/ # Language quality rules (with paths scope)
├── templates/skill-template.md # Skill extraction template
├── skills/ # Reusable workflow
├── scripts/ # Tool script
│ ├── setup/ # Install/uninstall/check script
│ ├── stats.sh # Statistical analysis
│ ├── quality-grader.sh # Quality grade rating (A/B/C/D)
│ ├── verify/doc-freshness-check.sh # Document freshness detection
│ ├── log-capability-change.sh # Capability evolution log
│ ├── constraint-recommender.py # preflight constraint automatic recommendation
│ ├── gc/gc-logs.sh # Log archive
│ ├── gc/gc-worktrees.sh # Worktree cleanup
│ ├── gc/gc-scheduled.sh # Regular GC (launchd scheduling, every Sunday at 3:00)
│ ├── project-init.sh # Project-level scaffolding (language detection + guard activation + pre-commit/pre-push installation)
│ ├── metrics/metrics-exporter.sh # Prometheus indicator export
│ └── ci/ # CI verification script
├── context-profiles/ # Context mode (dev/review/research)
└── docs/spec.md # Complete specification
```

## CLAUDE.md template

The warehouse comes with a complete CLAUDE.md template ([`docs/CLAUDE.md.example`](docs/CLAUDE.md.example)), which integrates Anthropic official best practices + VibeGuard seven-layer defense + Harness Golden Principles.

**Differences from the "10x Engineer CLAUDE.md" circulating on the Internet: ** Those configurations only tell the AI "what you should do", the VibeGuard version uses **automatic interception with Hooks + guard script enforcement** to ensure that the AI must do this.

### How to use

**Method 1: Install VibeGuard (recommended)**

```bash
bash ~/vibeguard/setup.sh
```

**Method 2: Only use templates without installing VibeGuard**

```bash
cp ~/vibeguard/docs/CLAUDE.md.example ./CLAUDE.md
```

> Note: Without installing VibeGuard, Hooks and `/vibeguard:*` commands will not take effect, only the rule constraint part will take effect.

**Method 3: OpenAI Codex User**

```bash
cp ~/vibeguard/templates/AGENTS.md ./AGENTS.md
bash ~/vibeguard/setup.sh
```

Constraints equivalent to CLAUDE.md, adapted to Codex agent format. `setup.sh` also automatically installs Codex skills and `~/.codex/hooks.json`.

### Codex adaptation layer (hooks + wrapper)

For `codex app-server` orchestration scenarios such as Symphony, you can optionally use an outer wrapper:

```bash
python3 ~/vibeguard/scripts/codex/app_server_wrapper.py \
  --codex-command "codex app-server"
```

Strategy mode parameters:

- `--strategy vibeguard` (default): enable outer pre/stop/post gate
- `--strategy noop`: pure transparent transmission (debugging)

**Method 4: Path scope rules (optional)**

```bash
mkdir -p .claude/rules
cp ~/vibeguard/templates/project-rules/*.md .claude/rules/
```

## Design concept

| Principles | Sources | Implementation |
|------|------|------|
| Mechanization first | Harness #3 | Hooks + guard script enforcement, not relying on AI consciousness |
| Error messages are repair instructions | Harness #3 | Each interception tells the AI how to fix it, not just what is wrong |
| Give the map but not the manual | Harness #5 | 32-row index + negative constraints + on-demand loading |
| Failure Closed Loop | Harness #2 | Make a mistake → learn → New guard → Don’t make the same mistake again |
| What Agent cannot see does not exist | Harness #1 | All decisions are written into the warehouse (CLAUDE.md / ExecPlan / Constraint Set) |
| Give Agent a pair of eyes | Harness #4 | Observable stack (log + indicator + alarm) |

## References

| External Practice | VibeGuard Correspondence |
|----------|---------------|
| Harness: Golden Principles written into the warehouse | CLAUDE.md seven-layer rule injection |
| Harness: Mechanical enforcement of architectural constraints | Pre/Post Hooks + Dependency Layer Linter |
| Harness: ExecPlan long-term task | `/vibeguard:exec-plan` 8-section template |
| Harness: Garbage Collection automatic cleaning | `/vibeguard:gc` three-module cleaning |
| Harness: Observable Stack | metrics-exporter + alerting-rules |
| Harness: Multi-Agent dispatch | dispatcher agent + classify_task() |
| Harness: Skills Progressive Disclosure | `/vibeguard:learn` Mode B + skill-template |
| Harness: Negative constraint guidance | "X does not exist" in the rule + AGENTS.md template |
| Stripe: Blueprint Orchestration | blueprints/*.json + blueprint-runner.sh |
| Stripe: Feedback left shift | pre-commit-guard.sh |
| Stripe: Tool subset distribution | Select corresponding guard scripts by language |

---

- [OpenAI Harness Engineering](https://openai.com/index/harness-engineering/)
- [Stripe Minions](https://www.youtube.com/watch?v=bZ0z1ApYjJo)
- [Anthropic: Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
