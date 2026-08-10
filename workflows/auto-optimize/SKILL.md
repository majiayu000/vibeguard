---
name: auto-optimize
description: Analyze a target project, classify findings, and implement at most one user-confirmed optimization with focused verification.
---
# Auto-Optimize: Bounded optimization process

Use VibeGuard to assess a project and deliver one bounded, verified optimization.

## When to Activate

- The user asks for repository optimization discovery and implementation.
- A project needs a rotating scan across security, quality, reliability, performance, and maintainability.
- Existing guard or audit findings should be converted into prioritized implementation work.
- The task needs an optimization report before deciding which fixes to execute.
- The user explicitly asks for optimization across quality, reliability, security, or DX dimensions.

## Red Flags

- The workflow starts without a bounded target or explicit authorization to implement.
- More than one writable session operates on the repository.
- A finding is repaired before it has evidence, classification, and a verification command.

## Checklist

- [ ] Confirm target, authorization, and done-when before execution.
- [ ] Classify every finding as FIX, SKIP, or DEFER with evidence.
- [ ] Run VibeGuard deterministic checks before and after implemented fixes.

## Execution Boundary

Start only when the user authorizes implementation and the optimization target is bounded. Keep one writable session for the repository and one short issue-sized batch per run.

Do not build coordinator/reviewer lanes by default. If the user explicitly requests delegation, follow [`workflows/references/delegation-contract.md`](../references/delegation-contract.md).

## Core principles (extracted from 30+ practical sessions)

1. **Not repairing is more important than repairing indiscriminately** — Each finding must be classified as FIX / SKIP / DEFER, and SKIP must be accompanied by a reason
2. **Scan Dimension Rotation** — Don’t just look for the same type of problems every time, rotate scans by dimension.
3. **Atomic Verification** — Verify the selected fix immediately rather than waiting until the end.
4. **Experience Persistence** — Record durable pitfalls only in an existing project memory system.
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
4. Scan the selected dimension; use read-only parallel help only when explicitly requested and useful.
5. **Merge guard results + LLM scan results**, output the evaluation report to the user, and confirm the optimization direction

### Phase 2: Classification and design (comply with VibeGuard specification)

Classify each finding into three categories:

```
FIX — Have a clear plan, don’t break the public API, benefits > risks
SKIP — with reasons: breaking change / over-engineering / not a bug / intentional design
DEFER — More information or a future user decision is required; keep it report-only
```

SKIP judgment criteria (load the rules of the corresponding language in the rules/ directory + VibeGuard specifications):
- Breaking public API signature → SKIP (unless user explicitly asks for breaking change)
- Only 1 use of "duplicate" → SKIP (extracting abstractions is over-engineering - VibeGuard Layer 5 minimal changes)
- Similar code with different semantics → SKIP (such as Span inline style vs Text global style)
- Macros can solve it but will reduce readability → SKIP
- Do not search for existing implementations before creating new files/classes/functions → Violates VibeGuard Layer 1, search first and then write

Record all classifications in the evaluation report, but select exactly one
bounded FIX for implementation. Do not turn the remaining findings into an
execution queue. DEFER items may be reported to the user, but they do not
become active tasks in this run.

The selected FIX must include:

- concrete evidence and root-cause hypothesis;
- owned files and a focused verification command;
- a stop condition that fits one short session;
- explicit user confirmation before implementation.

### Phase 3: Implement One Selected Finding

1. Confirm the worktree is clean enough to isolate the selected change and
   create one short-lived branch if a branch is needed.
2. Reproduce the selected finding and implement only its smallest complete fix.
3. Run the focused verification immediately.
4. If verification fails three times, stop and revisit the hypothesis. Do not
   move on to another finding.
5. Run the relevant broader project check before submission. Leave exhaustive
   platform coverage to CI.
6. Stop when the selected fix is verified. A new finding requires a new user
   decision and a new short session.

This workflow does not create `TASKS.md`, runner directories, coordinator
lanes, or autonomous queues. It does not invoke `auto-run-agent` or an
orchestrator.

### Phase 4: Closing and Learning (VibeGuard Compliance Check)

1. Run the relevant project test or build gate.
2. **Run VibeGuard Compliance Check** when it applies to the changed surface:
   ```bash
   bash "${VIBEGUARD_ROOT:-$(dirname "$0")/../..}/scripts/verify/compliance_check.sh" /path/to/project
   ```
3. Report any new findings without automatically fixing them.
4. Update an existing project memory file only when the repository already uses
   one and the lesson is durable.

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
- Phase 2 presents one recommended FIX for confirmation; the other findings remain report-only.
- A request to continue with another finding starts a separate short session.

## Notes
- The target project must be committed cleanly before branching to ensure that it can be rolled back
- One repository has at most one writable session. Read-only helpers may be used only when explicitly requested and given disjoint scope.

## Red Flags

- **Optimizing without a baseline** - improvements cannot be trusted if the current guard/test state was not recorded first.
- **Implementing low-priority cleanup first** - security and correctness findings take priority over style cleanup.
- **Creating tasks from stale notes** - old research must be checked against current files before becoming work.
- **Skipping user confirmation** - optimization direction must be confirmed before files are created or edited.

## Checklist

- [ ] Record the selected scan dimensions and current baseline.
- [ ] Search for existing fixes, plans, and guard coverage before proposing new tasks.
- [ ] Prioritize by security, logic, and data integrity before maintainability.
- [ ] Show the optimization report and one selected FIX before implementation.
- [ ] Attach a focused verification command to the selected finding.
- [ ] Stop after that finding is verified; do not drain a queue.
