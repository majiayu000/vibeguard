# Common Behavioral Constraints

## U-01: Respect the requested API contract (strict)
Preserve public APIs unless the requested change includes changing them. Use the project's versioning policy; do not demand a version bump or compatibility layer for every authorized breaking change.

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
**Compact guidance:** Keep changes localized. The configured size guard blocks new oversized files and growth beyond its limit; existing oversized files may be edited without growth.
The default guard advises above 400 lines and blocks new files or growth above 800 lines, subject to the project's configured limit. An existing oversized file may remain oversized when a change keeps or reduces its line count. Do not split unrelated code merely because the file is already over the limit. When growth is necessary, agree on an in-scope decomposition or use the owner's explicit project limit.

## U-17: Handle errors completely (strict)
**Compact guidance:** Handle errors completely. Do not swallow exceptions silently.
See U-29 for canonical error-handling guidance. U-17 keeps the compatibility-level principle: do not swallow exception or error paths; surface user-visible failures at error level or raise.

## U-18: Validate inputs (guideline)
Validate all user input at system boundaries. Internal code can trust framework guarantees.

## U-19: Follow the project's data-access boundaries (guideline)
Use the project's established data-access pattern. Add a Repository layer only when the requested design needs one; a database call alone does not require a new abstraction.

## U-20: Keep API response shapes consistent (guideline)
Follow the existing API contract and error conventions. Do not impose a universal response envelope or add an error-code registry unless the project requires it.

## U-21: Follow the project's commit convention (strict)
Explain why the change exists and follow the repository's commit format. Include Lore trailers only when that repository explicitly requires them; do not impose them on every project.

## U-22: Verify changed behavior (strict)
**Compact guidance:** Use the project's coverage policy and meaningful checks for changed behavior; no universal percentage or file-count quota.
Cover changed behavior, important failure paths, and regressions with the project's existing tests and tools. Preserve explicit coverage targets and test-first requirements. Documentation, configuration, and mechanical edits need checks appropriate to their actual effect, not tests that mirror the implementation.

**Mechanical checks (agent execution rules):**
- Run the relevant existing checks and report gaps precisely.
- Add regression coverage when needed to prove the changed behavior.
- Do not require a matching test filename for each source file or a new test solely because a refactor touched a fixed number of files.
- Preserve test integrity and update affected fixtures when the requested behavior changes.

## U-23: No silent degradation (strict)
See U-29 for canonical no-silent-degradation guidance. Unsupported strategies or configurations must fail explicitly or be marked as DEFER; do not invent default fallback semantics.

## U-24: Keep naming changes within scope (guideline)
Follow the project's naming and compatibility policy. Remove obsolete aliases when that is part of the authorized change; do not rename unrelated APIs, commands, or directories simply because an alias exists.

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

## U-32: Review instruction overload (guideline)
Treat instruction counts as a file-based estimate, not proof of runtime loading, semantic conflict, or task failure. The automatic hook is advisory in every profile, including strict.

**Review guidance:**
- Identify the actual conflicting or irrelevant instruction and the task it affects before proposing edits.
- Preserve owner requirements. A long, coherent instruction set does not automatically need splitting.
- Keep low-frequency details in the existing source or a relevant skill; do not create another policy layer solely to lower a count.
- State separately what is present, configured for discovery, and observed loaded.
- Continue authorized work when no substantive conflict blocks it. Do not rewrite global instructions merely to clear a numeric threshold.

**Inspection tools:**
Run `bash hooks/count_active_constraints.sh` for advisory context, or `python3 scripts/constraints/count_active_constraints.py --root . --include-canonical-rules --gc-report` for a maintainer inventory. Thresholds identify candidates for review. A maintainer may explicitly choose the offline `--fail-on-block` budget check; automatic task hooks never impose that choice.

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
