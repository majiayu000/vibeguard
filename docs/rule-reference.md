# VibeGuard Rule Reference

Index of the rule surface, mechanical enforcement points, and major per-language checks shipped in this repository.

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

## Common Rules (U-series: Code Style)

| ID | Name | Severity | Summary |
|----|------|----------|---------|
| U-01 | Immutable public API | Strict | Don't modify public function signatures without explicit breaking change approval |
| U-02 | No premature abstraction | Strict | Don't extract abstractions for code that appears only once. Wait for 3rd repetition |
| U-03 | No macro replacement | Strict | Don't replace readable repetitive code with macros. Only at 5+ identical patterns |
| U-04 | No unsolicited features | Strict | Bug fixes must stay scoped. No dependency upgrades in fix commits |
| U-05 | No silent deletion | Strict | Don't delete seemingly unused code without confirming. Mark DEFER instead |
| U-06 | Standard library first | Strict | Don't add new dependencies for problems solvable with stdlib |
| U-07 | No style changes in fixes | Strict | Style changes must be separate commits from functional changes |
| U-08 | No skipped validation | Strict | Every fix must independently pass lint + test |
| U-09 | Atomic commits | Strict | Don't bundle unrelated fixes in one commit |
| U-10 | No guessing intent | Strict | When uncertain, mark DEFER or ask user |
| U-11 | Unified DB/cache paths | High | All binaries must use a shared `default_db_path()` function |
| U-12 | No fallback path splits | High | First-run fallback logic must converge to same physical path |
| U-13 | Unified env var names | Medium | No `SERVER_DB_PATH` vs `DESKTOP_DB_PATH` — use `APP_DB_PATH` |
| U-14 | Unified base directories | Medium | All entry points must use the same base directory constructor |
| U-15 | Immutability preferred | Guideline | Create new objects instead of mutating. Function params are read-only |
| U-16 | File size control | Guideline | 200-400 lines typical, 800 line hard limit. Split beyond 800 |
| U-17 | Complete error handling | Strict | Handle all error paths. No silent swallowing. User-friendly error messages |
| U-18 | Input validation | Guideline | Validate all user input at system boundaries. Trust internal code |
| U-19 | Repository pattern | Guideline | Data access through Repository layer. Business logic doesn't touch DB directly |
| U-20 | Unified API response | Guideline | Standard envelope: `{ data, error, meta }`. Standardized error codes |
| U-21 | Commit message format | Guideline | Record why the change exists and keep decision context in git trailers |
| U-22 | Test coverage | Strict | New code minimum 80% line coverage. Critical paths 100% |
| U-23 | No silent degradation | Strict | Unsupported strategies must error explicitly, not fall back silently |
| U-24 | No aliases | Strict | No function/type/command/directory aliases. Find-and-replace old names |
| U-25 | Build failure priority | Strict | Build errors must be fixed before any new code. No coding on red |
| U-26 | Declaration-execution completeness | Strict | Declared components (Config/Trait/persist) must be wired at startup |
| U-27 | No fragile time assertions | Strict | Tests must not depend on tight timing windows. Use event sync instead |
| U-28 | Subprocess env isolation | Strict | Declare inherited/removed env vars before spawning subprocesses |
| U-29 | No silent degradation (data) | Strict | User-visible data loss must error, not warn+fallback |
| U-30 | Pydantic extra="allow" | Strict | Cross-boundary Pydantic models must use `extra="allow"` |
| U-31 | Cache key versioning | Strict | Builder/generation logic changes must increment cache version |

---

## Workflow Rules (W-series)

| ID | Name | Severity | Summary |
|----|------|----------|---------|
| W-01 | No root-cause-free fixes | Strict | Bug fixes require root cause identification first. No blind patching |
| W-02 | 3-failure backoff | Strict | After 3 consecutive failures on same issue, stop and reassess |
| W-03 | Verify before claiming done | Strict | Must have fresh verification evidence before claiming completion |
| W-04 | Test-first development | Guideline | Write failing test first, then minimal implementation, then refactor |
| W-05 | Sub-agent context isolation | Guideline | Each sub-agent gets only the minimum context it needs |
| W-10 | Publish confirmation (4-point) | Strict | Before publish/delete/deploy: confirm target, scope, untouched items, permission |
| W-11 | Fact/inference/suggestion separation | Strict | AI output must label each assertion as fact, inference, or suggestion |
| W-12 | Test integrity protection | Strict | Fix source code, not tests. Never manipulate test infrastructure to pass |
| W-13 | Analysis paralysis guard | Strict | 7+ consecutive read-only operations without writing = must act or report blocker |

---

## Security Rules (SEC-series)

| ID | Name | Severity | Summary |
|----|------|----------|---------|
| SEC-01 | SQL/NoSQL/OS injection | Critical | Use parameterized queries. Command execution with array args |
| SEC-02 | No hardcoded secrets | Critical | Use env vars or secret managers. `.env` in `.gitignore` |
| SEC-03 | XSS prevention | High | Use DOMPurify or framework escaping. No raw `innerHTML` |
| SEC-04 | API auth/authz | High | All API endpoints must have authentication middleware |
| SEC-05 | Known CVE dependencies | High | Run `npm audit` / `pip audit` / `cargo audit` regularly |
| SEC-06 | Weak crypto | High | No MD5/SHA1 for passwords. Use bcrypt/argon2 |
| SEC-07 | Path traversal | Medium | Validate and normalize file paths. Restrict to allowed base dirs |
| SEC-08 | SSRF | Medium | Whitelist target addresses for server-side requests |
| SEC-09 | Unsafe deserialization | Medium | No `pickle` / `yaml.load()`. Use `yaml.safe_load()` |
| SEC-10 | Sensitive data in logs | Medium | Mask passwords, tokens in log output with `***` |
| SEC-11 | Security logic visibility | High | Auth/authz checks must be explicit in business code, not hidden in decorators |
| SEC-12 | MCP Docker container leak | Medium | Prefer `uvx`/`npx` over `docker run -i` for MCP servers |
| SEC-13 | MCP tool poisoning | High | Audit MCP tool definitions after install. Diff on updates |

---

## Language-Specific Rules

### Rust

| Area | Key Rules |
|------|-----------|
| Error handling | No `.unwrap()` / `.expect()` in production code. Use `?` or explicit match |
| Concurrency | No nested mutex locks. Check for deadlock patterns |
| Architecture | Declaration-execution gap detection (U-26). Single source of truth |
| Types | No duplicate type definitions across modules |

### Python

| Area | Key Rules |
|------|-----------|
| Naming | `snake_case` internally, `camelCase` only at API boundaries |
| Pydantic | Cross-boundary models: `extra="allow"` (U-30). Track new fields end-to-end |
| Caching | Cache keys must include code version (U-31) |
| Quality | No dead re-export shims. No duplicate functions/classes |

### TypeScript

| Area | Key Rules |
|------|-----------|
| Types | No `any` abuse. Explicit types for public APIs |
| Debug | No `console.log` residue in production code |
| Components | No component duplication. No constant duplication |

### Go

| Area | Key Rules |
|------|-----------|
| Errors | All errors must be checked. No `_ = someFunc()` |
| Goroutines | No goroutine leaks. Always cancel contexts |
| Resources | No `defer` inside loops (resource leak) |

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
| `check_declaration_execution_gap.sh` | Declared but not wired components (U-26) |
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

Some guards support language-native suppression patterns, but suppression is guard-specific. Prefer fixing the root issue over suppressing findings.
