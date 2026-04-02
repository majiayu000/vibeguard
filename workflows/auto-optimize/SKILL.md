---
name: auto-optimize
description: Automate analysis, evaluation, design and optimization of target projects. Integrate VibeGuard as a baseline scan, the remediation process adheres to VibeGuard specifications, and a compliance check is run at the end. Support auto-run-agent autonomous execution.
---
# Auto-Optimize: Autonomous optimization process

Integrate the project autonomous optimization workflow of the VibeGuard guard system.

## Core principles (extracted from 30+ practical sessions)

1. **Not repairing is more important than repairing indiscriminately** — Each finding must be classified as FIX / SKIP / DEFER, and SKIP must be accompanied by a reason
2. **Scan Dimension Rotation** — Don’t just look for the same type of problems every time, rotate scans by dimension.
3. **Atomic Verification** — Each fix is independently verified and is not run until the end.
4. **Experience Persistence** — Write the pitfalls you have stepped on into MEMORY.md to avoid repeated mistakes across sessions
5. **Guard Priority** — Run VibeGuard deterministic guard first to obtain the baseline, and then use LLM deep scanning

## Scan dimensions (rotate by round)

| Round | Dimension | Scan Target |
|------|------|----------|
| 1 | Bug | Logic errors, deadlocks, TOCTOU, panic paths, boundary conditions |
| 2 | Architecture | Naming conflicts, confusion of responsibilities, module coupling, type design defects |
| 3 | Duplication | Code duplication, extractable common logic, copy-paste traces |
| 4 | Performance | Unnecessary clone/alloc, O(n2) paths, blocking calls |
| 5 | Testing | Missing coverage, fragile assertions, missing edge cases |
| 6 | API | Functional gaps, usability issues, and lack of documentation in competing products |
| 7 | Consistency | Multi-entry data path convergence, environment variable unification, configuration default value alignment, shared state schema consistency |

The user can specify the dimensions, otherwise the most needed dimensions will be automatically selected based on the current status of the project.

## Complete process

### Phase 1: Exploration and Assessment (Integrating VibeGuard)

1. Confirm the target project path (user-provided or current directory)
2. In-depth exploration project:
   - Read README, CLAUDE.md and other project specifications
   - Analyze project structure, technology stack, and dependencies
   - Read the core source code and understand the architecture
   - Check TODO/FIXME, #[allow(dead_code)] and other tags
3. **Run VibeGuard to get a baseline** (select by project language):
   ```bash
   # Directly call the guard script
   for guard in guards/python/check_*.sh; do bash "$guard" /path/to/project; done
   for guard in guards/rust/check_*.sh; do bash "$guard" /path/to/project; done
   ```
4. Scan in parallel according to the current dimension (use sub-agent to scan by module partition, load `rules/` corresponding language rules)
5. **Merge guard results + LLM scan results**, output the evaluation report to the user, and confirm the optimization direction

### Phase 2: Classification and design (comply with VibeGuard specification)

Classify each finding into three categories:

```
FIX — Have a clear plan, don’t break the public API, benefits > risks
SKIP — with reasons: breaking change / over-engineering / not a bug / intentional design
DEFER — More information or user decisions are required, logged in the backlog area of TASKS.md
```

SKIP judgment criteria (load the rules of the corresponding language in the rules/ directory + VibeGuard specifications):
- Breaking public API signature → SKIP (unless user explicitly asks for breaking change)
- Only 1 use of "duplicate" → SKIP (extracting abstractions is over-engineering - VibeGuard Layer 5 minimal changes)
- Similar code with different semantics → SKIP (such as Span inline style vs Text global style)
- Macros can solve it but will reduce readability → SKIP
- Do not search for existing implementations before creating new files/classes/functions → Violates VibeGuard Layer 1, search first and then write

FIX tasks are sorted by dependencies and generate a structured task list:
```markdown
## High priority
- [ ] [BUG] Description | Documentation | Solution Summary
- [ ] [BUG] ...

## Medium priority
- [ ] [DEDUP] Description | Documentation | Solution Summary
- [ ] [DESIGN] ...

## Architecture review (triggered after high/medium completion)
- [ ] [ARCH] Comprehensively review the rationality of the architecture, and add new tasks if problems are found

## Low priority
- [ ] [STYLE] ...

## Backlog（DEFER）
- [ ] [DEFER] Description | Required information
```

### Phase 3: Create Runner environment

1. Commit the current status and create a new branch in the target project (such as `auto-optimize`)
2. Create the runner directory structure:
```
<runner-dir>/
├── memory/
│ ├── TASKS.md # Task list for Phase 2 design
│ ├── CONTEXT.md # Project background, technology stack, specifications, architecture overview
│ └── DONE.md # Automatically generated
├── workspace/ # Soft link to the target project
├── logs/
└── config.yaml
```

3. CONTEXT.md must contain:
   - Project overview and technology stack
   - Architecture overview (key modules and responsibilities)
   - Project specifications (reference the project's own CLAUDE.md or coding specifications)
   - **VibeGuard specification reference** (remind workers to abide by the rules of search before writing, naming constraints, minimum changes, etc.)
   - Build and test commands (must be verified after every modification)
   - Commit specifications (if there are DCO requirements, etc.)
   - Current scanning dimensions and round records

4. config.yaml default configuration:
```yaml
max_iterations: 50
max_cost_usd: 0
max_duration: 6h
consecutive_no_progress: 3
stop_when_empty: true
cooldown_duration: 15s
worker_timeout: 30m
use_git_detection: true
```

5. Default path of runner directory: `~/<project-name>-runner/`

### Phase 4: Execution and Verification

**Prerequisite Check**: The `AUTO_RUN_AGENT_DIR` environment variable must be set and the directory must exist.

```bash
# Detect auto-run-agent
if [[ -z "${AUTO_RUN_AGENT_DIR:-}" ]]; then
  echo "AUTO_RUN_AGENT_DIR is not set, skip Phase 4"
  echo "Setting method: export AUTO_RUN_AGENT_DIR=/path/to/auto-run-agent"
  exit 0
fi
```

1. Start using auto-run-agent:
```bash
cd "${AUTO_RUN_AGENT_DIR}"
./orchestrator --dir <runner-dir> --max-iterations 50 --max-cost 0 --max-duration 6
```
2. Worker execution rules:
   - Run verification command (read from CONTEXT.md) immediately after each fix is completed
   - Verification failed → Roll back the fix immediately, mark it as DEFER, and continue with the next one
   - Verification passed → commit, marked as DONE, update DONE.md
   - Every time a fix is completed, check whether a new problem is triggered (regression detection)
3. Monitoring commands:
   - `tail -f <runner-dir>/logs/orchestrator_*.log` — real-time log
   - `cat <runner-dir>/memory/DONE.md` — View completion records
   - `cat <runner-dir>/memory/TASKS.md` — View remaining tasks

> **Note**: Phase 1-3 does not depend on auto-run-agent and can be used independently in an agent-less environment (manually execute TASKS.md).

### Phase 5: Closing and Learning (VibeGuard Compliance Check)

1. After all FIX are completed, run the full test suite
2. **Run VibeGuard Compliance Check**:
   ```bash
   bash "${VIBEGUARD_ROOT:-$(dirname "$0")/../..}/scripts/compliance_check.sh" /path/to/project
   ```
3. Fix the problems found in the compliance check (if any)
4. bump version（patch for fixes, minor for new features）
5. Update the project MEMORY.md to record the patterns and lessons discovered in this round
6. Record the scanning dimensions of this round and automatically switch to the next dimension next time

## Rule system

Rule files are located in the `rules/` directory and are organized by language. Rules corresponding to the language are automatically loaded during scanning.

```
auto-optimize/
├── SKILL.md
└── rules/
    ├── universal.md ← Universal rules (applicable to all languages)
    ├── python.md ← Python-specific rules (with VibeGuard cross-references)
    ├── rust.md ← Rust-specific rules
    ├── typescript.md ← TypeScript specific rules
    └── go.md ← Go specific rules
```

Rule format: Each rule has ID, category, description, and example. Workers refer to these rules to determine FIX/SKIP when scanning and repairing.

**Relationship to VibeGuard guards/**:
- `guards/` = deterministic detection tool (AST script, integrated into CI/pre-commit)
- `rules/` = LLM scanning reference (Markdown, guides workers to determine FIX/SKIP/DEFER)
- Overlapping parts (such as PY-02 naked exceptions) are processed through cross-reference and are not merged

## User interaction points
- After the completion of Phase 1, the evaluation report (including guard baseline + LLM scan results) must be shown to the user to confirm the optimization direction
- The task list of Phase 2 is displayed to the user for confirmation before creating the file.
- Ask the user before starting: number of iterations, time limit, and whether there is a cost limit
- Users can edit TASKS.md at any time to insert new tasks or adjust priorities

## Notes
- `AUTO_RUN_AGENT_DIR` environment variable specifies the auto-run-agent path, Phase 4 runtime detection
- The target project must be committed cleanly before branching to ensure that it can be rolled back
- Workspace uses soft links and does not copy code
- Multiple projects can run at the same time without affecting each other (note the API rate limit)
