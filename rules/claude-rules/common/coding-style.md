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
Every fix must independently pass lint and tests.

## U-09: Do not bundle unrelated fixes into one commit (strict)
Keep commits atomic so they are easy to review and revert.

## U-10: Do not guess user intent (strict)
If the intent is unclear, mark it as DEFER or ask the user to clarify.

## U-15: Prefer immutability (guideline)
Create new objects instead of mutating existing ones. Treat function parameters as read-only.

## U-16: Keep file size under control (guideline)
200-400 lines is typical, 800 lines is the hard ceiling. Files above 800 lines must be split.

## U-17: Handle errors completely (strict)
Cover error paths thoroughly. Do not swallow exceptions silently. Provide user-friendly error messages.

## U-18: Validate inputs (guideline)
Validate all user input at system boundaries. Internal code can trust framework guarantees.

## U-19: Use the Repository pattern (guideline)
Encapsulate data access in a Repository layer. Business logic should not operate directly on the database.

## U-20: Keep API response shapes consistent (guideline)
Use a standard envelope such as `{ data, error, meta }`. Standardize error codes.

## U-21: Commit messages must follow the Lore protocol (strict)
Record why the change exists, not just what changed. Use the repository's Lore trailers to preserve constraints, rejected alternatives, confidence, and verification evidence.

## U-22: Test coverage (strict)
New code must reach at least 80% line coverage. Critical paths require 100% coverage.

**Mechanical checks (agent execution rules)**:
- After modifying a source file, check whether a matching `*.test.*` or `*.spec.*` file exists.
- If not, and the file contains business logic rather than pure types/constants/styles, mark it as DEFER and tell the user.
- If a refactor touches more than three files, add at least one unit test that covers the changed core path.
- If you refactor hook or module interfaces, update every test mock that depends on the module shape as well (see TS-14).

## U-23: No silent degradation (strict)
Unsupported strategies or configurations must fail explicitly or be marked as DEFER. Do not silently fall back to a default strategy.

## U-24: No aliases (strict)
Do not keep function, type, command, or directory aliases. If you find the old name, replace it everywhere and delete the alias.

## U-25: Fix build failures first (strict)
When a build failure is detected, you must fix the build before continuing any other edits. Do not add new code while the build is red.

**Mechanical checks (agent execution rules)**:
- If you receive a build-failure warning after editing source code, the next step must be to fix that build error.
- After three consecutive build failures, run the full build command (`cargo check`, `npx tsc --noEmit`, `go build ./...`) to see the whole picture.
- Find the root cause first, usually type mismatches, missing imports, or unsynchronized interface changes, and fix it in one coherent pass rather than guessing one error at a time.
- Do not add unrelated feature code while the build is red.

## U-26: Declaration-execution completeness (strict)
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
If one rule file contains more than 30 active constraints, raise an overload warning. When a rule uses absolute language such as "always", "never", or "must", it also needs a downgrade path so the system does not create an illusion of control.

**Sources** (three-source convergence, 2026-04-16):
- Addy Osmani, "How to Write a Good Spec": the curse of instructions. Ten rules can be obeyed less reliably than five.
- Anthropic Claude Code Best Practices: a bloated `CLAUDE.md` causes Claude to ignore the instructions that actually matter.
- Martin Fowler, "Context Engineering": illusion of control is an anti-pattern. LLMs are probabilistic systems, so absolute language creates false guarantees.

**Mechanical checks**:
1. If a rule file contains more than 30 entries, recommend decomposing it into path-scoped child files (for example, only load Rust rules for `*.rs`).
2. If a rule uses absolute phrasing such as "ensure X", "never do Y", or "must be 100%", attach both:
   - A downgrade path: "If X is not feasible, fall back to Y and mark it stale."
   - An observability hook: a verification command or guard script that proves whether the rule is actually being followed.
3. If a global `CLAUDE.md` or `AGENTS.md` file grows beyond 100 lines, move material into skills or path-scoped rule files.

**Repair order**:
1. Audit the current rule set and annotate trigger frequency for each rule from access logs.
2. Candidate low-frequency rules (zero hits in the last 30 days) for removal or demotion into a skill.
3. Verify whether high-frequency rules use absolute language without a downgrade path.
4. Split large files by language or domain (`common/`, `rust/`, `python/`, `security/`).

**Additional checks**:
4. Before adding a persistent rule, first confirm it is a high-frequency, stable, cross-task constraint; otherwise prefer a skill, hook, or verify script.
5. Long workflow templates, one-off playbooks, and low-frequency knowledge should not live permanently in `CLAUDE.md` or `AGENTS.md`; convert them into an index plus on-demand documents.

**Anti-patterns**:
- A single file accumulates 50+ rules and expects all of them to remain active at once.
- New rules are added without deleting stale rules, relying on overlap to resolve conflict.
- A rule says "must never do X" but offers no answer for unavoidable edge cases.
- Suggestions or conventions get promoted to strict rules in an attempt to force compliance, which makes them easier to ignore.
- Low-frequency specialized workflows stay in persistent context instead of moving to a skill, hook, or verify script.
- A second summary repeats the canonical rule text and drifts away from the real source.
