# Learning and Skill generation system

> Status: architecture note with dated examples.
> File names and data flows referenced here are useful for understanding the learning pipeline, but current behavior should be verified against `hooks/learn-evaluator.sh`, `hooks/skills-loader.sh`, `scripts/gc/gc-scheduled.sh`, and `hooks/log.sh`.


VibeGuard's learning system benchmarks the feedback loop of OpenAI Harness, realizing a complete closed loop of "operation → event collection → signal detection → learning extraction → Skill file → automatic loading".

## Three-tier architecture

```
┌─────────────────────────────────────────────────────────┐
│ The third layer: generation layer (/vibeguard:learn explicitly called) │
│ Mode A: Error → Guard rules/hook defense direction, strengthen the defense line │
│ Mode B: Discovery → SKILL.md file Accumulate direction and accumulate experience │
├─────────────────────────────────────────────────────────┤
│ Second layer: Evaluation layer (automatically triggered) │
│   Stop hook：learn-evaluator.sh → session-metrics.jsonl │
│ GC scheduled: gc-scheduled.sh → learn-digest.jsonl │
├─────────────────────────────────────────────────────────┤
│ The first layer: collection layer (automatic recording of each operation) │
│ runtime hooks → log.sh vg_log → events.jsonl │
└─────────────────────────────────────────────────────────┘
```

## First layer: event collection

All Hooks are written to `events.jsonl` through the `vg_log` function of `log.sh` when executed.

### Log format

```json
{
  "ts": "2026-03-02T03:29:41Z",
  "session": "49e12e90",
  "hook": "post-edit-guard",
  "tool": "Edit",
  "decision": "warn",
  "reason": "unwrap detected in non-test code",
  "detail": "src/main.rs",
  "duration_ms": 42
}
```

### Log isolation

Isolated by project hash, events from different projects are completely independent:

```
~/.vibeguard/projects/
├── a1b2c3d4/ # Project A (the first 8 digits of SHA256 of the git root path)
│   ├── events.jsonl
│   └── session-metrics.jsonl
├── e5f6g7h8/ # Project B
│   ├── events.jsonl
│   └── session-metrics.jsonl
└── learn-digest.jsonl # GC regular learning output (cross-project summary)
```

### Trigger link

| Hook | Trigger timing | Write content |
|------|----------|----------|
| pre-edit-guard | Before editing | Check whether the file exists |
| pre-write-guard | Before creating new | Search reminder first |
| pre-bash-guard | Before command | Dangerous command interception |
| post-edit-guard | After editing | unwrap/console.log/hardcoded/Go error discarded/oversized diff |
| post-write-guard | After new creation | Duplicate definition detection |
| skills-loader | Manual optional first Read | Skill/learning prompt loading (default is not registered, no log is written) |
| learn-evaluator | Stop | Session metric aggregation |

### Session ID mechanism

Guaranteed stable ID sharing within the same session via file persistence + 30 minute renewal:

```
~/.vibeguard/.session_id # Store the current session ID
  ├─ File exists & mtime < 30min → reuse + touch renewal
  └─ Otherwise → generate new 8-character hex ID
```

## Second layer: evaluation layer

### 2a. End-of-session evaluation (learn-evaluator.sh)

The Stop event is triggered and the event indicators in the last 30 minutes are aggregated:

```json
{
  "ts": "2026-03-02T11:57:00Z",
  "session": "49e12e90",
  "event_count": 35,
  "decisions": {"warn": 12, "pass": 20, "block": 3},
  "hooks": {"post-edit-guard": 15, "pre-bash-guard": 8},
  "tools": {"Edit": 19, "Bash": 12},
  "top_edited_files": {"src/main.tsx": 19, "app.py": 6},
  "avg_duration_ms": 380,
  "slow_ops": 2
}
```

Write to `session-metrics.jsonl`, always `exit 0` non-blocking.

### 2b. GC regular learning (gc-scheduled.sh learning phase)

It is triggered by launchd at 3 a.m. every Sunday, and collected from **two signal sources**:

#### Signal source A: event log (agent behavior mode)

| Signal | Detection logic | Meaning |
|------|----------|------|
| `repeated_warn` | The same reason ≥10 times/week | Making the same mistake repeatedly |
| `chronic_block` | The same reason is blocked ≥5 times/week | Agent repeatedly hits the wall |
| `hot_files` | The same file is edited ≥20 times/week | Highly modified area |
| `slow_sessions` | Slow operations ≥10 times/week | Complex scenes |
| `warn_escalation` | Warn grows >50% in the second half of the week | Guards are degrading |

#### Signal source B: code scanning (linter violation, benchmarking Harness GC Agent)

Obtain the project physical path through the `.project-root` mapping file, automatically detect the language, and run the corresponding guards:

| project type | guards |
|---------|--------|
| All | `check_code_slop.sh` (empty catch, debug residue, expired TODO, dead code, overlong files) |
| Rust | `check_unwrap_in_prod.sh` / `check_nested_locks.sh` / `check_duplicate_types.sh` etc. |
| TypeScript | `check_any_abuse.sh` / `check_console_residual.sh` / `check_duplicate_constants.sh` |
| Go | `check_error_handling.sh` / `check_goroutine_leak.sh` / `check_defer_in_loop.sh` |

≥5 violations generate the `linter_violations` signal.

#### Unified output

```json
{
  "ts": "2026-03-02T03:00:00Z",
  "project": "a1b2c3d4",
  "project_root": "/Users/me/code/my-app",
  "signals": [
    {"type": "repeated_warn", "source": "events", "reason": "unwrap detected", "count": 23},
    {"type": "linter_violations", "source": "code_scan", "guard": "console_residual", "count": 96}
  ]
}
```

#### Current-project preview

Interactive learning can inspect the current project without waiting for scheduled
GC and without writing digest state:

```bash
VIBEGUARD_REPO_DIR="${VIBEGUARD_REPO_DIR:-$(cat "$HOME/.vibeguard/repo-path" 2>/dev/null)}"
test -f "$VIBEGUARD_REPO_DIR/scripts/gc/learn_digest.py" || { echo "VibeGuard repo path missing; rerun setup.sh from a VibeGuard checkout" >&2; exit 1; }
python3 "$VIBEGUARD_REPO_DIR/scripts/gc/learn_digest.py" --scope current --project-root "$PWD" --dry-run --format json --no-code-scan
```

Preview resolves the project log under `~/.vibeguard/projects/<hash>/` by
`.project-root`, `--project-root`, or `--project-hash`. It reads only that log
directory for `--scope current`; use `--scope global` with `--max-projects` for
bounded cross-project inspection. Preview output includes `partial` and
`truncated_reason` when `--budget-ms`, `--max-events`, `--max-projects`, or
`--guard-timeout` stops analysis early. Code scanning remains opt-in for
preview via `--code-scan`; keep `--no-code-scan` for the lightweight default.
Hot-file signals are attributed to the current project root; external edit paths
are reported as diagnostic noise instead of current-project hot files.

**Anti-repetitive learning (triage state):**

`~/.vibeguard/learn-state.jsonl` stores explicit append-only transitions keyed
by `signal_id`. `skills-loader.sh` previews pending signals from
`learn-digest.jsonl` and never advances a watermark or changes triage state.
Signals are hidden only after an explicit `adopt`, `skip`, or `snooze`
transition.

```
learn-digest.jsonl:  signal A, signal B, signal C
learn-state.jsonl:   signal A -> adopted
Next display:        signal B, signal C remain pending
```

**Benchmarking against Harness GC Agent:**

| Harness GC Agent | VibeGuard GC Learning |
|-----------------|-------------------|
| Codex agent **Scan code base** | guards script scan (signal source B) |
| Simultaneously analyze behavior logs | events.jsonl analysis (signal source A) |
| Scan against Golden Principles | Scan against the native VibeGuard rule set |
| Violation → **Open PR directly** | Violation → learn-digest → Recommended user handling |
| Automatic review and merge (<1 minute) | Semi-automatic (/vibeguard:learn is executed after user confirmation) |

## The third layer: Skill generation

Triggered explicitly via the `/vibeguard:learn` command, dual-mode routing.

### Pattern routing

| input | routing |
|------|------|
| User describes error/bug/guard failure | **Mode A**: error analysis → output guard/hook/rule |
| User said "extract" / "Extract experience" | **Mode B**: Experience extraction → Output SKILL.md |
| Stop hook automatically triggered (no parameters) | Evaluate first → select A or B as needed |
| Both bug fixes and non-obvious findings | A + B both executed |

### Mode A: Error → Guard Rule (Defensive Orientation)

**Full process (9 steps):**

```
1. Automatic pattern recognition - read events.jsonl and extract the top 5 high-frequency warn/block patterns
2. Collect error context — parameters + dialogue + automatic recognition results
3. 5-Why root cause analysis:
   ├─ Superficial reason: What wrong operation did the Agent perform?
   ├─ Direct reason: Why didn’t the existing guards stop him?
   └─ Root cause: What is missing at the system level?
4. Determine the type of improvement:
   ├─ New guard script → guards/<lang>/check_xxx.sh
   ├─ Enhance existing guards → Edit script under guards/
   ├─ New hook rules → Modify scripts under hooks/
   ├─ New rule entry → Modify the rules file under rules/
   └─ New constraints → Modify vibeguard-rules.md
5. [Stop] AskUserQuestion Confirm Solution
6. Implement improvements
7. Pattern recognition and rule generation (6 types of errors → corresponding rule types)
8. Verification (original scenario + no regression)
9. Output learning report
```

**6 Class Error Pattern → Rule Type Mapping:**

| Pattern | Generate rule type |
|------|-------------|
| Repeatedly create files with the same function | Guard script (detect similar file names/function names) |
| Path illusion (edit non-existent files) | Hook rules (pre-edit check for file existence) |
| API hallucination (calling a method that does not exist) | Rule entries (marking the real API list) |
| Over-engineering (adding unnecessary abstractions) | Constraint items (enhancing the minimum change principle) |
| Data splitting (multiple entries with different paths) | Guard script (cross-entry path consistency check) |
| Naming confusion (multiple names for the same concept) | Naming specification entries + alias detection |

### Mode B: Discovery → SKILL.md (accumulation direction)

**Full process (8 steps):**

```
1. Self-assessment (5 questions, continue if any one is "yes"):
   ├─ Involving non-obvious debugging?
   ├─ Can the solution be reused in the future?
   ├─ Discovered knowledge not covered by the documentation?
   ├─ Is the error message misleading?
   └─ Did you find the solution through trial and error?
2. Deduplication check — rg searches .claude/skills/ and ~/.claude/skills/
3. Extract knowledge - question + non-obvious part + trigger condition
4. Conditional Web research (3 types of scenarios need to be searched)
5. Structured into SKILL.md with activation cues, Red Flags, and a checklist
6. Save location decisions (project-level vs. global)
7. [Stop] AskUserQuestion Confirm
8. Output extraction report and run the SKILL.md format gate
```

**4 quality gates (extract only when all are met): **

| Standard | Definition | Counterexample |
|------|------|------|
| Reusable | Can be used for similar tasks in the future | "This variable name is typed incorrectly" |
| Non-trivial | Requires exploration to discover | "npm install installation dependencies" |
| Specific | With precise trigger conditions and steps | "React sometimes reports an error" |
| Verified | Actual tested | "It should be solved with XX" |

**Format gate:** generated skills must include `## When to Activate`, `## Red Flags`, and `## Checklist`.
`## Red Flags` and `## Checklist` must contain useful list items, not empty prose or template placeholders.
Validate a single draft with:

```bash
python3 scripts/skill_validate.py --format-only --proposed-skill path/to/SKILL.md
```

### SKILL.md file structure

```yaml
---
name: descriptive-kebab-case-name
description: |
  [Precise description: (1) What problem is solved (2) Triggering conditions (3) Technology/framework involved]
author: Claude Code
version: 1.0.0
date: YYYY-MM-DD
---
```

Text: Problem -> When to Activate -> Red Flags -> Checklist -> Solution(step-by-step) -> Verification -> Example(Before/After) -> Notes -> References

Every generated skill must include:

- `## When to Activate` with concrete trigger bullets.
- `## Red Flags` with at least three specific anti-patterns or failure modes.
- `## Checklist` with at least three `- [ ]` pre-delivery items.

Run `bash scripts/ci/validate-skill-format.sh` before accepting the skill into this repository; the gate also validates `templates/skill-template.md` so future skills do not start from a stale shape.

### Deduplication decision table

| Search results | Actions |
|----------|------|
| Unrelated | New Skill |
| Same trigger + same scheme | Update existing (version + minor) |
| Same trigger + different root causes | New, two-way addition See also |
| Same field + different triggers | Update existing, add "Variations" section |
| Existing but obsolete | Marked as obsolete, replaced by new one |

## Skill automatic reuse

`skills-loader.sh` is now kept as an optional script and will not be automatically registered by setup by default.
If you need to manually hook into `PreToolUse(Read)`, it will trigger two things on the first `Read` operation of a new session:

```
New Session → First Read
  │
  ├─ [Learning Recommendation] Read pending signals from learn-digest.jsonl
  │ ├─ There is a new signal → Output recommendations and prompt to run /vibeguard:learn
  │ └─ Display is read-only; only explicit triage commands append learn-state.jsonl
  │
  ├─ [Skill Match] Scan ~/.claude/skills/ and .claude/skills/
  │ ├─ Read the frontmatter (name + description) of each SKILL.md
  │ ├─ Score: +2 for language match, +3 for project name match
  │ └─ Output top 5 matching Skill prompts
  │
  └─Create a flag file so that it will not be loaded repeatedly in this session
```

**Actual output example:**

```
[VibeGuard Learning Recommendations] 3 cross-session learning signals detected:
  - High frequency warning: 1 build error (37 times)
  - Hot files: .../src/scrapers/candidate-scraper.ts (42 times)
  - Hot files: .../src/components/DealDocsTab.tsx (113 times)
Run /vibeguard:learn to extract guard rules or skills from these signals.

[VibeGuard Skills] 5 related Skills detected:
  - vibeguard: AI-assisted development of anti-hallucination specifications...
  - eval-harness: Evaluation-driven development...
```

## Complete closed loop

```
Operation ──→ Hook detection ──→ events.jsonl record
                              │
              ┌───────────────┼───────────────┐
              ↓               ↓               ↓
      End-of-session evaluation GC periodic analysis /vibeguard:learn
   (session-metrics) (learn-digest) (explicit call)
              │               │               │
              └───────────────┼───────────────┘
                              ↓
                    Learning Signals + User Confirmation
                              │
                    ┌─────────┴─────────┐
                    ↓                   ↓
              Mode A: Guard Mode B: Skill
            (guards/hooks/rules)  (SKILL.md)
                    │                   │
                    ↓                   ↓
              Hook loads and executes skills-loader matching
                    │                   │
                    └─────────┬─────────┘
                              ↓
                      guide future operations
```

## Learning output history

### 2026-03-11: Declaration-Execution Gap pattern learning

**Signal source**: Harness project cross-session memory analysis + user questions

**Pattern recognition**: Config/Trait/persistence layer declared but not integrated at startup → configuration does not take effect/state is lost/function is degraded

| Cases | Symptoms | Root Causes |
|------|------|------|
| SkillStore.discover() | skills lost after restart | discover() never called at startup |
| RulesConfig.load() | Configuration file does not take effect | Default::default() for consumers |
| ThreadManager.persist() | Dead code | persist() is never called on startup |
| GC project_root | Function downgrade | Parameters are not propagated to subtasks |

**output**:
- New rule **U-26**: Declaration-Execution Integrity (strict) — 4-item checklist + silent fallback mode
- New rule **RS-14**: Statement-Execution Gap (High) — Rust-specific instrumentation mode
- New guard: `guards/rust/check_declaration_execution_gap.sh` — detects type 4 gaps
- New Skill: `declaration-execution-gap-detector` (`~/.claude/skills/`)

**Three-layer triggering mechanism**:
```
U-26 rules (resident, effective for all sessions)
  ↓ Found declaration but not integrated
Skill knowledge (providing audit and remediation strategies)
  ↓ Rust projects
RS-14 Guard (automatically detects Category 4 gaps)
```

### 2026-03-11: Build error loop analysis

**Signal source**: 57 projects 3/5~3/11 event aggregation + learn-digest backlog signal

| Signal | Times | Improvement |
|------|------|------|
| Build errors | 435x warn | U-25 rules + post-build-check escalation |
| L1 duplicate definition | 82x warn | Already detected, not upgraded yet |
| RS-03 unwrap | 37x warn | message enhancement ("fix now") |
| File does not exist | 14x block | Effectively intercepted, no improvement required |

**output**:
- New rule **U-25**: build failure fixes first (strict)
- Hook enhancement: `post-build-check.sh` fails 5 times in a row → escalate
- New Skill: `build-error-spiral-breaker` (`~/.claude/skills/`)

**Three-layer triggering mechanism**:
```
U-25 rules (resident, effective for all sessions)
  ↓ When the build fails
Skill knowledge (providing specific repair strategies)
  ↓ 5 consecutive failures
Hook upgrade (forced warning, interrupting Agent cycle)
```

## File list

| Files | Roles |
|------|------|
| `hooks/log.sh` | Logging infrastructure, providing vg_log function |
| `hooks/learn-evaluator.sh` | Session indicator collection during Stop event |
| `hooks/skills-loader.sh` | Optional first Read Skill/learning prompt script (not enabled by default) |
| `hooks/post-build-check.sh` | Build check + continuous failed upgrade (U-25 mechanized) |
| `scripts/gc/gc-scheduled.sh` | GC scheduled learning (cross-session pattern recognition) |
| `.claude/commands/vibeguard/learn.md` | /vibeguard:learn command (dual-mode routing) |
| `templates/skill-template.md` | SKILL.md writing template |
| `scripts/skill_validate.py --check-repo-format --repo-root .` | Repository-owned skill/workflow format gate |
| `skills/*/SKILL.md` | Extracted Skill files |

## Benchmarking with OpenAI Harness

| Harness concept | VibeGuard implementation |
|-------------|---------------|
| GC background regular learning | gc-scheduled.sh learning phase (cross-project signal summary) |
| Skill manual extraction | /vibeguard:learn mode B |
| Failure-driven improvements | /vibeguard:learn Mode A (5-Why + guard generation) |
| Optional prompt loading | skills-loader.sh (can be manually linked to PreToolUse Read) |
| Knowledge deduplication | Deduplication decision table (5 processing paths) |
| Quality Gating | 4 criteria (reusable, non-trivial, specific, verified) + SKILL.md format gate |
