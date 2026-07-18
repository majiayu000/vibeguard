# Common Behavioral Constraints

## U-01: Do not change public API signatures (strict)
Unless the user explicitly requests a breaking change and accepts a MAJOR version bump, do not change public function signatures.

## U-02: Do not extract abstractions for code that appears only once (strict)
Three lines of duplication are better than one premature abstraction. Wait until the third repetition before extracting.

## U-03: Do not replace readable duplication with macros (strict)
Macros reduce readability and IDE support. Only use them when repetition appears in more than five places and the pattern is truly identical.

## U-04: Do not add features the user did not ask for (strict)
Keep bug-fix scope tight. Do not refactor surrounding code "while you are here."

## U-05: Do not delete code that merely looks unused without confirming first (strict)
It may be a work-in-progress feature. Mark it as DEFER instead of deleting it blindly.

## U-06: Do not add dependencies for problems the standard library can solve (strict)
Use the standard library first. Avoid dependency bloat.

## U-07: Do not change code style while fixing behavior (strict)
Style-only edits should be a separate commit.

## U-08: Do not skip verification steps (strict)
See W-03 and W-16 for canonical verification guidance. U-08 keeps the compatibility-level principle: a fix is not complete until focused lint, test, or check evidence for the changed surface was produced in the current session.

## U-09: Do not bundle unrelated fixes into one commit (strict)
Keep commits atomic so they are easy to review and revert.

## U-10: Do not guess user intent (strict)
If the intent is unclear, mark it as DEFER or ask the user to clarify.

## U-15: Prefer immutability (guideline)
Create new objects instead of mutating existing ones. Treat function parameters as read-only.

## U-16: Keep file size under control (guideline)
**Compact guidance:** Keep file size under control: 200-400 lines typical, 800 lines hard ceiling. Files above 800 must be split.
200-400 lines is typical, 800 lines is the hard ceiling. Files above 800 lines must be split.

## U-17: Handle errors completely (strict)
**Compact guidance:** Handle errors completely. Do not swallow exceptions silently.
See U-29 for canonical error-handling guidance. U-17 keeps the compatibility-level principle: do not swallow exception or error paths; surface user-visible failures at error level or raise.

## U-18: Validate inputs (guideline)
Validate all user input at system boundaries. Internal code can trust framework guarantees.

## U-19: Use the Repository pattern (guideline)
Encapsulate data access in a Repository layer. Business logic should not operate directly on the database.

## U-20: Keep API response shapes consistent (guideline)
Use a standard envelope such as `{ data, error, meta }`. Standardize error codes.

## U-21: Commit messages must follow the Lore protocol (strict)
Record why the change exists, not just what changed. Use the repository's Lore trailers to preserve constraints, rejected alternatives, confidence, and verification evidence.

## U-22: Test coverage (strict)
**Compact guidance:** New code minimum 80% line coverage; critical paths 100%.
New code must reach at least 80% line coverage. Critical paths require 100% coverage.

**Mechanical checks (agent execution rules)**:
- After modifying a source file, check whether a matching `*.test.*` or `*.spec.*` file exists.
- If not, and the file contains business logic rather than pure types/constants/styles, mark it as DEFER and tell the user.
- If a refactor touches more than three files, add at least one unit test that covers the changed core path.
- If you refactor hook or module interfaces, update every test mock that depends on the module shape as well (see TS-14).

## U-23: No silent degradation (strict)
See U-29 for canonical no-silent-degradation guidance. Unsupported strategies or configurations must fail explicitly or be marked as DEFER; do not invent default fallback semantics.

## U-24: No aliases (strict)
Do not keep function, type, command, or directory aliases. If you find the old name, replace it everywhere and delete the alias.

## U-25: Fix build failures first (strict)
**Compact guidance:** Fix build failures first before any other edit; do not add new code while build is red.
When a build failure is detected, you must fix the build before continuing any other edits. Do not add new code while the build is red.

**Mechanical checks (agent execution rules)**:
- If you receive a build-failure warning after editing source code, the next step must be to fix that build error.
- After three consecutive build failures, run the full build command (`cargo check`, `npx tsc --noEmit`, `go build ./...`) to see the whole picture.
- Find the root cause first, usually type mismatches, missing imports, or unsynchronized interface changes, and fix it in one coherent pass rather than guessing one error at a time.
- Do not add unrelated feature code while the build is red.

## U-26: Declaration-execution completeness (strict)
**Compact guidance:** Declaration-execution completeness: declared Config / Trait / persistence layers must be wired into startup.
When you declare framework components such as configs, traits, persistence layers, or state containers, you must also finish the startup integration. Do not leave components declared-but-unwired.

**Checklist**:
- Config structs: startup code must call `load()` instead of defaulting via `Default::default()`.
- Trait declarations: there must be at least one `impl` and a startup registration point such as a registry or builder.
- Persistence methods (`save`, `load`, `persist`, `restore`): startup code must call the restore path.
- New fields added to `AppState` / `Context`: initialize them at every construction site.

**Repair flow**:
1. Audit all declaration sites (`rg "struct.*Config"`, `rg "trait "`, `rg "fn.*(save|load|persist)"`).
2. Verify the corresponding startup registration path (`build_app_state()`, `main()`, `init()`, `new()`).
3. Add the missing registration call.
4. Implement silent fallback only where it is intentional and safe (for example, missing config falls back to defaults without breaking startup).

**Anti-patterns**:
- `SkillStore` has a `discover()` method but startup never calls it, so skills disappear after restart.
- `RulesConfig` loads from TOML but consumers still call `Default::default()`, so config changes never take effect.
- `ThreadManager` exposes `persist()` but nothing ever calls it, leaving dead code.
- GC receives `project_root` but never propagates it to child tasks, causing functional downgrade.

## U-32: Rule overload threshold + absolute-language detection (strict)
Keep the effective constraint set for a single agent task at 15 or fewer items. If the live task context exceeds 15 constraints, warn and split lower-frequency material into path-scoped child files, skills, hooks, or verify scripts. If it exceeds 30 constraints, block and require decomposition before continuing. When a rule uses absolute language such as "always", "never", or "must", it also needs a downgrade path so the system does not create an illusion of control.

**Sources**:
- arXiv 2605.06445 (Constraint Decay, 2026-05-09 RSS scout): across 80 greenfield and 20 feature tasks over 8 web frameworks, stronger agents lost about 30 assertion-pass-rate points as structured constraints accumulated; data-layer defects were the dominant failure mode.
- Addy Osmani, "How to Write a Good Spec": the curse of instructions. Ten rules can be obeyed less reliably than five.
- Anthropic Claude Code Best Practices: a bloated `CLAUDE.md` causes Claude to ignore the instructions that actually matter.
- Martin Fowler, "Context Engineering": illusion of control is an anti-pattern. LLMs are probabilistic systems, so absolute language creates false guarantees.

**Mechanical checks**:
1. Count the actual task-loaded constraint set: global memory files, project `AGENTS.md`/`CLAUDE.md`, active skill files, and path-scoped native rules that match the current task files.
2. If the live task context contains more than 15 effective constraints, emit a U-32 warning and recommend moving lower-frequency material to path-scoped child files, skills, hooks, or verify scripts.
3. If the live task context contains more than 30 effective constraints, block the task until the constraint set is decomposed.
4. If a rule file contains more than 30 entries, recommend decomposing it into path-scoped child files (for example, only load Rust rules for `*.rs`).
5. If a rule uses absolute phrasing such as "ensure X", "never do Y", or "must be 100%", attach both:
   - A downgrade path: "If X is not feasible, fall back to Y and mark it stale."
   - An observability hook: a verification command or guard script that proves whether the rule is actually being followed.
6. If a global `CLAUDE.md` or `AGENTS.md` file grows beyond 100 lines, move material into skills or path-scoped rule files.
7. Run `bash hooks/count_active_constraints.sh` through the strict hook profile, or run `python3 scripts/constraints/count_active_constraints.py --root . --include-canonical-rules --gc-report` manually, to inspect the current budget and downgrade candidates.

**Repair order**:
1. Count the current task's effective constraints before adding any new persistent instruction.
2. Audit the current rule set and annotate trigger frequency for each rule from access logs.
3. Candidate low-frequency rules (zero hits in the last 30 days) for removal or demotion into a skill.
4. Verify whether high-frequency rules use absolute language without a downgrade path.
5. Split large files by language or domain (`common/`, `rust/`, `python/`, `security/`) and attach path frontmatter where possible.

**Additional checks**:
1. Before adding a persistent rule, first confirm it is a high-frequency, stable, cross-task constraint; otherwise prefer a skill, hook, or verify script.
2. Long workflow templates, one-off playbooks, and low-frequency knowledge should not live permanently in `CLAUDE.md` or `AGENTS.md`; convert them into an index plus on-demand documents.

**Anti-patterns**:
- A single file accumulates 50+ rules and expects all of them to remain active at once.
- New rules are added without deleting stale rules, relying on overlap to resolve conflict.
- A rule says "must never do X" but offers no answer for unavoidable edge cases.
- Suggestions or conventions get promoted to strict rules in an attempt to force compliance, which makes them easier to ignore.
- Low-frequency specialized workflows stay in persistent context instead of moving to a skill, hook, or verify script.
- A second summary repeats the canonical rule text and drifts away from the real source.

## U-33: Code search defaults to glob/grep; large codebases require structural navigation (strict)

For agent code retrieval, plain glob/grep driven by the model remains the default for small and medium single-repository work. When the codebase is at least 400K lines of code or the task spans repositories, lexical search alone must be augmented with structural navigation before escalating to vector DB or RAG.

**Sources** (multi-source convergence, updated 2026-05-18):
- Boris Cherny (Anthropic Claude Code lead), Pragmatic Engineer interview, 2026-03-04: "plain glob and grep, driven by the model, beat everything." Anthropic explicitly rejected local vector DB and recursive model-based indexing in production due to stale-index and permission-complexity problems.
- Sebastian Raschka, "Components of a Coding Agent" (2026-04-04): file tools listed as the canonical retrieval primitive in the 6-component agent framework; states "much of apparent model quality is really context quality."
- LangChain, "How agents can use filesystems for context engineering" (2026-04-27): cites Claude Code, Manus, and Deep Agents as production examples of filesystem-as-context.
- zilliztech/claude-context (TypeScript, 9884 stars, last updated 2026-04-28, verified via `gh api repos/zilliztech/claude-context`): production MCP that exposes the codebase via filesystem-style traversal rather than as an embedding index.
- Sourcegraph, "Why coding agents fail in large codebases (and what to do about it)" (2026-05-08): CodeScaleBench found agents with only local tools begin to struggle systematically above roughly 400K LOC; code intelligence tools had a +0.259 reward delta in the 400K-2M LOC band, with structural navigation called out as the fix for wrong-symbol and lost-in-codebase failures.

**Mechanical checks (agent execution rules)**:
- When designing a code-retrieval feature for an agent, the default tool set for small and medium single-repository work must be `ls`, `glob`, `grep`, `rg`, `find`, plus repository-aware variants (`git grep`, `gh search code`).
- At session start, estimate effective project size with existing project inventory, `tokei`, `cloc`, or an equivalent method when the task may exceed one package or repository; generated, vendored, and dependency code may be excluded if the exclusion is documented.
- If the effective codebase is at least 400K LOC, add structural navigation to the retrieval plan: go-to-definition, find-references, type hierarchy, symbol search, code graph, or MCP-exposed code-intelligence tools.
- Multi-repository tasks must include cross-repository reference lookup, or explicitly report that cross-repo code intelligence is unavailable.
- If the agent or the user proposes adding a vector DB, embedding index, or RAG layer to a coding agent, require a one-paragraph justification covering: (1) the specific retrieval task glob/grep cannot solve; (2) the staleness/permission strategy for the index; (3) cost and latency vs grep on the same workload.
- Reject "grep failed, so we need vector DB" arguments unless structural navigation was tried first or was explicitly unavailable.
- Cross-language semantic search (e.g. "find the function that loads YAML config across Go and Python files") may justify a vector DB; same-repo lexical or symbol search does not.
- More than 50 keyword or grep-style searches on one task is retrieval thrashing; stop, reassess the search strategy, and switch to structural navigation or report the missing code-intelligence capability before continuing.

**Downgrade path** (U-32 compliance):
If the project already ships a vector DB and removing it is out of scope, mark the existing component as `legacy: vector-db` in the README or architecture doc and require the justification at the next significant change to retrieval logic. If a large or multi-repo codebase has no LSP, code graph, or code-intelligence tool available, report degraded retrieval instead of treating grep-only exploration as satisfying this rule. Small single-package fixes do not require a full LOC census.

**Relation to U-19** (Repository pattern):
U-19 covers business data access via a Repository abstraction. U-33 explicitly carves out agent code retrieval as a domain where wrapping a vector DB in a Repository layer is an anti-pattern, not best practice — the Unix toolset is the abstraction.

**Anti-patterns**:
- "We need semantic search for the codebase" — almost always means grep plus disciplined naming, and then structural navigation at large scale, were never tried.
- Building an embedding index because "it feels faster" without measuring grep cost on the actual codebase.
- Re-indexing on every commit to fight staleness; grep has no staleness because it reads the live tree.
- Treating "RAG" as the default architecture for any retrieval problem, including code.
