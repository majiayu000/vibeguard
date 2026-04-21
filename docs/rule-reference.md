# VibeGuard Rule Reference

> Generated from `rules/claude-rules/**` by `python3 scripts/generate_rule_docs.py`. Do not edit by hand.

Index of the current rule surface, the major enforcement layers, and the shipped per-language checks in this repository.

Canonical source of truth: `rules/claude-rules/`

## Layer Architecture

| Layer | Enforcement | Mechanism |
|-------|------------|-----------|
| L1 | Search before create | `pre-write-guard.sh` hook (block) |
| L2 | Naming conventions | `check_naming_convention.py` guard |
| L3 | Quality baseline | `post-edit-guard.sh` hook (warn/escalate) |
| L4 | Data integrity | Rules injection + guards |
| L5 | Minimal changes | Rules injection |
| L6 | Process gates | `/vibeguard:preflight` + `/vibeguard:interview` + `/vibeguard:exec-plan` |
| L7 | Commit discipline | `pre-commit-guard.sh` hook (block) |

---

## Common Rules (U-series)

| ID | Name | Severity | Summary |
| --- | ---- | -------- | ------- |
| U-01 | Do not change public API signatures | Strict | Unless the user explicitly requests a breaking change and accepts a MAJOR version bump, do not change public function signatures. |
| U-02 | Do not extract abstractions for code that appears only once | Strict | Three lines of duplication are better than one premature abstraction. |
| U-03 | Do not replace readable duplication with macros | Strict | Macros reduce readability and IDE support. |
| U-04 | Do not add features the user did not ask for | Strict | Keep bug-fix scope tight. |
| U-05 | Do not delete code that merely looks unused without confirming first | Strict | It may be a work-in-progress feature. |
| U-06 | Do not add dependencies for problems the standard library can solve | Strict | Use the standard library first. |
| U-07 | Do not change code style while fixing behavior | Strict | Style-only edits should be a separate commit. |
| U-08 | Do not skip verification steps | Strict | Every fix must independently pass lint and tests. |
| U-09 | Do not bundle unrelated fixes into one commit | Strict | Keep commits atomic so they are easy to review and revert. |
| U-10 | Do not guess user intent | Strict | If the intent is unclear, mark it as DEFER or ask the user to clarify. |
| U-11 | Inconsistent default DB/cache paths across binaries | High | Different entry points hardcode different data paths, which splits user data. |
| U-12 | Shared-data fallback creates the wrong file on first boot | High | Fallback logic can create a split file during first startup. |
| U-13 | Environment variable names diverge across entry points | Medium | For example, `SERVER_DB_PATH` and `DESKTOP_DB_PATH` point at different defaults. |
| U-14 | CLI default path uses a different base directory than GUI/server | Medium | Different entry points use different base directories. |
| U-15 | Prefer immutability | Guideline | Create new objects instead of mutating existing ones. |
| U-16 | Keep file size under control | Guideline | 200-400 lines is typical, 800 lines is the hard ceiling. |
| U-17 | Handle errors completely | Strict | Cover error paths thoroughly. |
| U-18 | Validate inputs | Guideline | Validate all user input at system boundaries. |
| U-19 | Use the Repository pattern | Guideline | Encapsulate data access in a Repository layer. |
| U-20 | Keep API response shapes consistent | Guideline | Use a standard envelope such as `{ data, error, meta }`. |
| U-21 | Commit messages must follow the Lore protocol | Strict | Record why the change exists, not just what changed. |
| U-22 | Test coverage | Strict | New code must reach at least 80% line coverage. |
| U-23 | No silent degradation | Strict | Unsupported strategies or configurations must fail explicitly or be marked as DEFER. |
| U-24 | No aliases | Strict | Do not keep function, type, command, or directory aliases. |
| U-25 | Fix build failures first | Strict | When a build failure is detected, you must fix the build before continuing any other edits. |
| U-26 | Declaration-execution completeness | Strict | When you declare framework components such as configs, traits, persistence layers, or state containers, you must also finish the startup... |
| U-29 | Error-driven downgrade paths must be observable at error level | Strict | If an error causes user-visible missing data or incorrect output, you must log it at `error` level or raise it. |
| U-30 | Cross-boundary Pydantic models must use `extra="allow"` | Strict | Any Pydantic model that receives external or cross-boundary data must set `extra="allow"` so `model_validate()` does not silently drop un... |
| U-31 | Cache keys must include code version | Strict | When builder or generation logic changes, old cache entries must invalidate automatically. |
| U-32 | Rule overload threshold + absolute-language detection | Strict | If one rule file contains more than 30 active constraints, raise an overload warning. |

---

## Workflow Rules (W-series)

| ID | Name | Severity | Summary |
| --- | ---- | -------- | ------- |
| W-01 | No fixes without root cause | Strict | Every bug fix must identify the root cause before changing code. |
| W-02 | Back off after 3 consecutive failures | Strict | If you fail to fix the same problem three times in a row, stop and question the hypothesis or the architectural direction. |
| W-03 | Verify before claiming completion | Strict | Before saying "fixed" or "done", produce fresh verification evidence. |
| W-04 | Test first | Guideline | For new features, prefer writing the failing test first, then writing the minimum implementation needed to pass it. |
| W-05 | Sub-agent context isolation | Guideline | When using sub-agents, give each child only the minimum context required for its task. |
| W-10 | Require four confirmations before publish, deletion, or remote deploy | Strict | Before any irreversible or high-risk action, confirm four items with the user and wait for explicit approval. |
| W-11 | LLM output must separate facts, inferences, and suggestions | Strict | When an agent produces an analysis report, technical judgment, or architecture recommendation, it must label the source of confidence for... |
| W-12 | Protect test integrity | Strict | When tests fail, fix the production code rather than manipulating the test harness. |
| W-13 | Analysis paralysis guard | Strict | If there are 7+ consecutive read-only actions (Read / Glob / Grep) with no write action, you must either act or report a blocker. |
| W-14 | Parallel-agent file ownership | Strict | When multiple agents work in parallel, prompts must assign explicit file ownership so agents cannot silently overwrite one another. |
| W-15 | Low-information loop detection | Strict | If the information gain shrinks for three consecutive rounds, stop that direction and report it. |
| W-16 | Verification commands must come from this session | Strict | When you say "fixed", "done", or "verified", you must cite command output produced in this session. |
| W-17 | Fewer smarter gates beat more mechanical gates | Strict | When the user asks to add a new gate or rule, first ask whether an existing gate can absorb the new condition instead of creating one mor... |

---

## Security Rules (SEC-series)

| ID | Name | Severity | Summary |
| --- | ---- | -------- | ------- |
| SEC-01 | SQL / NoSQL / OS command injection | Critical | String concatenation is used to build queries or commands. |
| SEC-02 | Hardcoded keys / credentials / API tokens | Critical | Secrets are written directly in code. |
| SEC-03 | Unescaped user input rendered directly into HTML | High | This creates an XSS vulnerability. |
| SEC-04 | API endpoints missing authentication or authorization checks | High | Unprotected API endpoints. |
| SEC-05 | Dependencies with known CVEs | High | Dependencies with known CVEs |
| SEC-06 | Weak cryptographic algorithms | High | Using MD5 or SHA1 for password hashing. |
| SEC-07 | File paths are not validated | Medium | Path traversal risk. |
| SEC-08 | Server-side requests allow arbitrary target addresses | Medium | SSRF risk. |
| SEC-09 | Unsafe deserialization | Medium | Examples include `pickle` and `yaml.load`. |
| SEC-10 | Logs contain sensitive information | Medium | Passwords or tokens appear in logs. |
| SEC-11 | AI-generated code security defect baseline | Strict | AI-generated code carries materially higher security risk than hand-written code, so review intensity must increase accordingly. |
| SEC-12 | Silent drift in MCP tool descriptions | Strict | The description field of an MCP tool is effectively an instruction fed to the LLM. |
| SEC-13 | High-context file integrity protection | Strict | `AGENTS.md`, `CLAUDE.md`, `.claude/settings*.json`, `.claude//*.md`, and rule or skill definitions are high-context files. |

---

## Language-Specific Rules

### Rust

| ID | Name | Severity | Summary |
| --- | ---- | -------- | ------- |
| RS-01 | Nested `RwLock` / `Mutex` acquisition | High | Holding multiple locks at once creates deadlock risk. |
| RS-02 | TOCTOU — `get()` followed by `insert()` | High | The lock is released between read and write, which creates a race. |
| RS-03 | `unwrap()` in non-test code | Medium | `unwrap()` creates panic risk. |
| RS-04 | Multiple `Signal` / `Arc` objects manage the same logical state | Medium | Converge them into a single `Signal<State>` so one structure owns the whole state. |
| RS-05 | Same name, different meaning types | Medium | For example, two different `RenderHandle` types. |
| RS-06 | The same match arm is duplicated across multiple methods | Medium | The same match arm is duplicated across multiple methods |
| RS-07 | Manual field-by-field copying | Low | Use merge or apply methods instead. |
| RS-08 | Unnecessary `clone()` calls | Low | Often appears on `Copy` types or values that could be borrowed. |
| RS-09 | `format!()` allocation in hot paths | Low | `format!()` allocation in hot paths |
| RS-10 | Meaningful `Result`s are silently discarded | High | Patterns like `let _ =`, `.ok()`, or `.unwrap_or_default()` swallow errors. |
| RS-11 | Different modules use different infrastructure for the same system | Medium | Logging, config paths, or DB connection strategies drift across modules. |
| RS-12 | Two systems coexist for one responsibility | High | For example, `Todo*` and `TaskManagement*` both handle task state. |
| RS-13 | Action-named functions lack state side effects | High | A function like `mark_done` only returns text but does not persist state. |
| RS-14 | Declaration-execution gap | High | Configs, traits, or persistence layers are declared but never integrated into startup. |
| RS-20 | After changing struct fields or enum variants, inspect the full chain | Strict | If you add, remove, rename, or retag a struct field or enum variant, "it compiles" is not enough. |
| TASTE-ANSI | Hardcoded ANSI escape sequences | Medium | Use a crate like `colored` or `termcolor` instead of hardcoding `\x1b[` sequences. |
| TASTE-ASYNC-UNWRAP | `.unwrap()` inside `async fn` | Medium | Async code should propagate errors with `?` instead of panicking with `unwrap()`. |
| TASTE-PANIC-MSG | `panic!()` without a meaningful message | Medium | `panic!()` or `panic!("")` lacks context. |

### Python

| ID | Name | Severity | Summary |
| --- | ---- | -------- | ------- |
| PY-01 | Mutable default parameters | High | `def f(x=[])` shares state across calls. |
| PY-02 | Bare `except` blocks | Medium | `except:` or `except Exception` without logging or re-raising. |
| PY-03 | `await` inside loops without `gather()` / `TaskGroup` | Medium | Serial waiting wastes time. |
| PY-04 | God class larger than 500 lines | Medium | More than 10 public methods. |
| PY-05 | Repeated try/except patterns across many locations | Medium | Repeated try/except patterns across many locations |
| PY-06 | Rebuilding regexes inside loops | Low | Rebuilding regexes inside loops |
| PY-07 | String concatenation inside loops | Low | String concatenation inside loops |
| PY-08 | Use of `eval()`, `exec()`, or `__import__()` | High | This dynamically executes untrusted code. |
| PY-09 | Functions longer than 50 lines | Medium | Functions longer than 50 lines |
| PY-10 | Nesting deeper than 4 levels | Medium | Nesting deeper than 4 levels |
| PY-11 | File operations without a `with` context manager | Medium | File operations without a `with` context manager |
| PY-12 | Repeated calls to `len()`, `keys()`, or `values()` inside loops | Low | Repeated calls to `len()`, `keys()`, or `values()` inside loops |
| PY-13 | Dead compatibility shim | Medium | A file that only re-exports symbols from another module and adds no behavior should be removed after migration is complete. |
| U-30 | Cross-boundary Pydantic models must use `extra="allow"` | Strict | Any Pydantic model that receives external or cross-boundary data must set `extra="allow"` so `model_validate()` does not silently drop un... |
| U-31 | Cache keys must include code version | Strict | When builder or generation logic changes, old cache entries must invalidate automatically. |

### TypeScript

| ID | Name | Severity | Summary |
| --- | ---- | -------- | ------- |
| TS-01 | `any` type escape | Medium | Function parameters or return values use `any`. |
| TS-02 | Unhandled Promise rejections | High | Async calls lack error handling. |
| TS-03 | `==` instead of `===` | Medium | Loose equality is used outside explicit null checks. |
| TS-04 | Oversized component larger than 300 lines | Medium | React component is too large. |
| TS-05 | Repeated fetch / API call patterns across the codebase | Medium | Repeated fetch / API call patterns across the codebase |
| TS-06 | `useEffect` has missing or overly broad dependencies | Medium | `useEffect` has missing or overly broad dependencies |
| TS-07 | Large arrays are mapped during render without memoization | Low | Large arrays are mapped during render without memoization |
| TS-08 | Bypassing type checks with `as any` or `@ts-ignore` | High | Bypassing type checks with `as any` or `@ts-ignore` |
| TS-09 | Functions with more than 4 parameters | Medium | Functions with more than 4 parameters |
| TS-10 | Callback nesting deeper than 3 levels | Medium | Callback nesting deeper than 3 levels |
| TS-11 | Unhandled `null` / `undefined` | Medium | Missing optional chaining or null guards. |
| TS-12 | Passing full objects as component props instead of only required fields | Low | Passing full objects as component props instead of only required fields |
| TS-13 | Duplicate component or hook behavior under different names | High | Multiple files define React components or hooks with equivalent behavior but different names. |
| TS-14 | Test mocks drift from the real module shape | High | `vi.mock()` and `jest.mock()` factory functions often return `any`, so TypeScript cannot tell when the mock shape drifts from the real mo... |

### Go

| ID | Name | Severity | Summary |
| --- | ---- | -------- | ------- |
| GO-01 | Unchecked error return values | High | Errors are assigned to `_` and discarded. |
| GO-02 | Goroutine leak | High | `go func()` launches work without an exit path. |
| GO-03 | Data race | High | Shared variables are accessed without a mutex or channel protection. |
| GO-04 | Interface is declared on the implementation side instead of the consumer side | Medium | Interface is declared on the implementation side instead of the consumer side |
| GO-05 | Repeated error-wrapping patterns across multiple places | Medium | Repeated error-wrapping patterns across multiple places |
| GO-06 | `append` in loops without preallocated capacity | Low | `append` in loops without preallocated capacity |
| GO-07 | String concatenation with `+` instead of `strings.Builder` | Low | String concatenation with `+` instead of `strings.Builder` |
| GO-08 | `defer` inside loops | High | This risks resource leaks because deferred calls wait until the function returns. |
| GO-09 | Functions longer than 80 lines | Medium | Functions longer than 80 lines |
| GO-10 | Package-level `init()` has side effects | Medium | Network or file I/O happens in `init()`. |
| GO-11 | `context.Background()` is used outside entry points | Medium | `context.Background()` is used outside entry points |
| GO-12 | Struct fields are not ordered by size | Low | This wastes memory due to alignment padding. |

---

## Guard Scripts

Static analysis scripts that enforce rules mechanically:

### Universal

| Script | Detects |
|--------|---------|
| `check_code_slop.sh` | AI-generated boilerplate and stale-code patterns |
| `check_dependency_layers.py` | Import hierarchy violations |
| `check_circular_deps.py` | Circular dependency chains |
| `check_test_integrity.sh` | Test shadowing and test-environment integrity problems |

### Rust

| Script | Detects |
|--------|---------|
| `check_unwrap_in_prod.sh` | `.unwrap()` / `.expect()` in non-test code |
| `check_nested_locks.sh` | Deadlock-prone nested mutex acquisitions |
| `check_declaration_execution_gap.sh` | Declared but not wired components |
| `check_workspace_consistency.sh` | Cargo workspace inconsistencies |
| `check_duplicate_types.sh` | Type definition duplication |
| `check_taste_invariants.sh` | Architectural invariant violations |
| `check_semantic_effect.sh` | Semantic correctness issues |
| `check_single_source_of_truth.sh` | Multiple definitions of the same concept |

### Python

| Script | Detects |
|--------|---------|
| `check_duplicates.py` | Duplicate functions, classes, and Protocols |
| `check_naming_convention.py` | Mixed naming conventions |
| `check_dead_shims.py` | Dead re-export compatibility shims |

### TypeScript

| Script | Detects |
|--------|---------|
| `check_any_abuse.sh` | Excessive `any` type usage |
| `check_console_residual.sh` | Lingering `console.log` statements |
| `check_component_duplication.sh` | Component file duplication |
| `check_duplicate_constants.sh` | Constant value duplication |

`eslint-guards.ts` is a shared helper used by some TypeScript checks; it is not a standalone guard entry point.

### Go

| Script | Detects |
|--------|---------|
| `check_error_handling.sh` | Unchecked error returns |
| `check_goroutine_leak.sh` | Goroutine leak patterns |
| `check_defer_in_loop.sh` | `defer` inside loops |

Some guards support language-native suppression patterns, but suppressions are guard-specific. Prefer fixing the root issue over suppressing a finding.
