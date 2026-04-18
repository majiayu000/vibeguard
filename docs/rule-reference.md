# VibeGuard Rule Reference

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
|----|------|----------|---------|
| U-01 | Immutable public API | Strict | Do not change public signatures without explicit breaking-change approval |
| U-02 | No premature abstraction | Strict | Wait for the third repetition before extracting shared code |
| U-03 | No macro replacement | Strict | Prefer readable duplication over early macro use |
| U-04 | No unsolicited features | Strict | Keep fixes scoped to the requested task |
| U-05 | No silent deletion | Strict | Do not delete apparently unused code without confirmation |
| U-06 | Standard library first | Strict | Avoid new dependencies when stdlib is enough |
| U-07 | No style churn in fixes | Strict | Separate formatting or style changes from behavior changes |
| U-08 | No skipped verification | Strict | Every fix needs independent validation |
| U-09 | Atomic commits | Strict | Do not mix unrelated changes into one commit |
| U-10 | No guessing intent | Strict | Mark DEFER or ask when intent is unclear |
| U-11 | Unified DB/cache paths | High | Shared binaries must converge on one physical data path |
| U-12 | No split fallback paths | High | First-run fallback logic must not create a second data file |
| U-13 | Unified env var names | Medium | Shared entry points should not use divergent path variable names |
| U-14 | Unified base directories | Medium | CLI, GUI, and server should build paths from the same helper |
| U-15 | Immutability first | Guideline | Prefer creating new objects over mutation |
| U-16 | File size control | Guideline | 200-400 lines typical, 800 lines hard limit |
| U-17 | Complete error handling | Strict | Handle all error paths and do not swallow failures silently |
| U-18 | Input validation | Guideline | Validate external input at system boundaries |
| U-19 | Repository pattern | Guideline | Keep data access in repository layers |
| U-20 | Unified API envelope | Guideline | Standardize response shapes such as `{ data, error, meta }` |
| U-21 | Lore commit protocol | Strict | Commit history should preserve why the change exists, not just what changed |
| U-22 | Test coverage | Strict | New code needs 80% line coverage; critical paths need 100% |
| U-23 | No silent degradation | Strict | Unsupported paths must fail explicitly instead of silently falling back |
| U-24 | No aliases | Strict | Replace old names completely instead of preserving compatibility aliases |
| U-25 | Build failure priority | Strict | Fix the red build before adding more code |
| U-26 | Declaration-execution completeness | Strict | Declared config/trait/persistence components must be wired into startup |
| U-29 | Observable degradation | Strict | User-visible data loss or wrong output must surface at error level |
| U-30 | Pydantic cross-boundary preservation | Strict | External-facing Pydantic models must use `extra="allow"` |
| U-31 | Cache key versioning | Strict | Builder and generation logic changes must invalidate stale cache output |
| U-32 | Rule overload threshold | Strict | Large rule sets need decomposition, downgrade paths, and observability |

---

## Workflow Rules (W-series)

| ID | Name | Severity | Summary |
|----|------|----------|---------|
| W-01 | No root-cause-free fixes | Strict | Reproduce and explain the bug before changing code |
| W-02 | 3-failure backoff | Strict | After three failed attempts on the same issue, stop and reassess |
| W-03 | Verify before claiming done | Strict | Completion claims require fresh evidence |
| W-04 | Test-first development | Guideline | Prefer RED -> GREEN -> REFACTOR for new work |
| W-05 | Sub-agent context isolation | Guideline | Give child agents only the minimum context they need |
| W-10 | Publish confirmation (4-point) | Strict | Confirm target, scope, untouched items, and approval before destructive actions |
| W-11 | Fact / inference / suggestion separation | Strict | Label claims by evidence type and confidence |
| W-12 | Test integrity protection | Strict | Fix production code, not the test harness |
| W-13 | Analysis paralysis guard | Strict | Seven read-only steps in a row must end in action or a blocker report |
| W-14 | Parallel agent file ownership | Strict | Parallel agents need disjoint write scopes |
| W-15 | Low-information loop detection | Strict | Stop after three shrinking-yield rounds |
| W-16 | Fresh-session verification evidence | Strict | "Fixed" claims must cite verification from this session |
| W-17 | Fewer smarter gates | Strict | Extend an existing gate before creating another overlapping rule |

---

## Security Rules (SEC-series)

| ID | Name | Severity | Summary |
|----|------|----------|---------|
| SEC-01 | SQL / NoSQL / OS injection | Critical | Use parameterized queries and array-style command arguments |
| SEC-02 | No hardcoded secrets | Critical | Store keys and credentials outside source code |
| SEC-03 | XSS prevention | High | Escape or sanitize user input before rendering HTML |
| SEC-04 | API auth/authz | High | All protected endpoints need authentication and authorization checks |
| SEC-05 | Known-CVE dependencies | High | Audit and replace vulnerable dependencies |
| SEC-06 | Weak crypto | High | Do not use weak algorithms for passwords or secrets |
| SEC-07 | Path traversal | Medium | Validate and normalize file paths against allowed base directories |
| SEC-08 | SSRF | Medium | Restrict server-side requests to approved destinations |
| SEC-09 | Unsafe deserialization | Medium | Avoid unsafe loaders like `pickle` or `yaml.load()` on untrusted input |
| SEC-10 | Sensitive data in logs | Medium | Redact passwords, tokens, and other secrets in log output |
| SEC-11 | AI-generated code defect baseline | Strict | High-risk security domains need elevated review when AI authored code |
| SEC-12 | MCP tool description drift | Strict | Tool descriptions must be hashed and audited for silent prompt changes |

---

## Language-Specific Rules

### Rust

| ID | Summary |
|----|---------|
| RS-01 | Avoid nested `RwLock` / `Mutex` acquisition |
| RS-02 | Replace `get()` + `insert()` races with the Entry API |
| RS-03 | No `unwrap()` in non-test code |
| RS-04 | Keep one logical state in one `Signal<State>` |
| RS-05 | Same-name different-meaning types should converge |
| RS-06 | Factor duplicated match arms into shared logic |
| RS-07 | Avoid manual field-by-field copies |
| RS-08 | Remove unnecessary `clone()` calls |
| RS-09 | Avoid `format!()` allocation in hot paths |
| RS-10 | Do not silently discard meaningful `Result`s |
| RS-11 | Keep infra consistent across modules |
| RS-12 | Do not keep dual systems for one responsibility |
| RS-13 | Action-named functions must change state or emit events |
| RS-14 | Close declaration-execution gaps |
| RS-20 | Audit constructors, serde, DB mappings, and fixtures after struct or enum changes |
| TASTE-ANSI | Avoid hardcoded ANSI sequences |
| TASTE-ASYNC-UNWRAP | Avoid `.unwrap()` inside `async fn` |
| TASTE-PANIC-MSG | Provide meaningful `panic!()` messages |

### Python

| ID | Summary |
|----|---------|
| PY-01 | Avoid mutable default parameters |
| PY-02 | Avoid bare `except` without logging or re-raise |
| PY-03 | Do not `await` serially inside loops when parallelism is expected |
| PY-04 | Split God classes |
| PY-05 | Deduplicate repeated try/except patterns |
| PY-06 | Precompile regexes used in loops |
| PY-07 | Avoid string concatenation in loops |
| PY-08 | Avoid `eval()`, `exec()`, and `__import__()` on dynamic input |
| PY-09 | Split functions longer than 50 lines |
| PY-10 | Reduce nesting deeper than 4 levels |
| PY-11 | Use `with` for file operations |
| PY-12 | Cache repeated size/key lookups outside loops |
| PY-13 | Remove dead compatibility shims once migration is complete |
| U-30 | Cross-boundary Pydantic models should use `extra="allow"` |
| U-31 | Cache keys should include a code version |

### TypeScript

| ID | Summary |
|----|---------|
| TS-01 | Avoid `any` escapes in public surfaces |
| TS-02 | Handle Promise rejections |
| TS-03 | Use `===` except for deliberate nullish checks |
| TS-04 | Split oversized React components |
| TS-05 | Deduplicate repeated fetch / API call patterns |
| TS-06 | Keep `useEffect` dependencies precise |
| TS-07 | Memoize expensive render-time array mapping |
| TS-08 | Avoid `as any` and `@ts-ignore` escape hatches |
| TS-09 | Collapse long parameter lists into options objects |
| TS-10 | Flatten deeply nested callbacks |
| TS-11 | Guard `null` and `undefined` explicitly |
| TS-12 | Pass only required props, not whole objects |
| TS-13 | Reuse equivalent components and hooks instead of renaming duplicates |
| TS-14 | Keep test mocks aligned with the real module shape |

### Go

| ID | Summary |
|----|---------|
| GO-01 | Check every error return value |
| GO-02 | Prevent goroutine leaks with cancellation |
| GO-03 | Protect shared state from data races |
| GO-04 | Define interfaces on the consumer side |
| GO-05 | Standardize error wrapping |
| GO-06 | Preallocate slice capacity when appending in loops |
| GO-07 | Use `strings.Builder` or `strings.Join` for repeated concatenation |
| GO-08 | Do not `defer` inside loops without isolating scope |
| GO-09 | Split functions longer than 80 lines |
| GO-10 | Keep `init()` side-effect free |
| GO-11 | Pass `context.Context` instead of creating root contexts deep in the call stack |
| GO-12 | Order struct fields to reduce padding where it materially helps |

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
