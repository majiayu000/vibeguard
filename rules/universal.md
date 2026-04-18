# Universal Rules

Reference index for VibeGuard rules that apply across languages, workflows, and repository boundaries.

## Common code and architecture rules

| ID | Rule | Severity | Summary |
|----|------|----------|---------|
| U-01 | Immutable public API | Strict | Do not change public signatures without explicit breaking-change approval |
| U-02 | No premature abstraction | Strict | Wait for the third repetition before extracting shared code |
| U-03 | No macro replacement | Strict | Keep readable duplication unless the pattern is repeated broadly and identically |
| U-04 | No unsolicited features | Strict | Keep fixes scoped to the requested change |
| U-05 | No silent deletion | Strict | Do not delete apparently unused code without confirmation |
| U-06 | Standard library first | Strict | Do not add dependencies for problems the standard library can solve |
| U-07 | No style churn in fixes | Strict | Separate style-only edits from behavior changes |
| U-08 | No skipped verification | Strict | Every fix needs its own lint/test proof |
| U-09 | Atomic commits | Strict | Do not bundle unrelated fixes together |
| U-10 | No guessing user intent | Strict | Mark DEFER or ask when intent is unclear |
| U-11 | Unified DB/cache paths | High | Shared binaries must converge on one physical data path |
| U-12 | No split fallback paths | High | First-run fallback logic must not create a second data file |
| U-13 | Unified env var names | Medium | Different entry points should not use divergent path variable names |
| U-14 | Unified base directories | Medium | CLI, GUI, and server should build paths from the same base helper |
| U-15 | Immutability first | Guideline | Prefer new objects over mutation |
| U-16 | File size control | Guideline | 200-400 lines typical, 800 line hard limit |
| U-17 | Complete error handling | Strict | Cover error paths and never swallow exceptions silently |
| U-18 | Input validation | Guideline | Validate external input at system boundaries |
| U-19 | Repository pattern | Guideline | Keep data access in repository layers |
| U-20 | Unified API envelope | Guideline | Standardize response shapes such as `{ data, error, meta }` |
| U-21 | Lore commit protocol | Strict | Commit messages should record why the change exists, with structured trailers |
| U-22 | Test coverage | Strict | New code needs 80% line coverage; critical paths need 100% |
| U-23 | No silent degradation | Strict | Unsupported paths must fail explicitly instead of silently falling back |
| U-24 | No aliases | Strict | Remove old names instead of preserving compatibility aliases indefinitely |
| U-25 | Build failure priority | Strict | Fix the red build before adding more code |
| U-26 | Declaration-execution completeness | Strict | Declared config/trait/persistence components must be wired into startup |
| U-29 | Observable degradation | Strict | User-visible data loss or wrong output must surface at error level |
| U-30 | Pydantic `extra="allow"` at cross-boundary seams | Strict | External-facing Pydantic models must preserve undeclared fields |
| U-31 | Cache key versioning | Strict | Builder and generation logic changes must invalidate stale cache entries |
| U-32 | Rule overload threshold | Strict | Large rule sets need decomposition, downgrade paths, and observability |

## Workflow and process rules

| ID | Rule | Severity | Summary |
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

## FIX / SKIP / DEFER guidance

| Condition | Judgment |
|------|------|
| Logic bugs, deadlocks, TOCTOU, panic risks | FIX - high priority |
| Shared data path drift or split fallback files | FIX - high priority |
| Duplicate logic with identical semantics and meaningful maintenance cost | FIX - medium priority |
| Similar-looking code with different semantics | SKIP - keep separate |
| Naming conflicts that create conceptual ambiguity | FIX - medium priority |
| Performance issue outside hot paths | SKIP - not enough value |
| Performance issue inside hot paths | FIX - medium priority |
| Missing tests on otherwise stable code | DEFER - document the gap |
| Missing tests on known-buggy code | FIX - high priority |
| Style inconsistency without behavior risk | SKIP - keep separate from functional work |
| Scope touches more than half the repository | DEFER - requires explicit scope confirmation |
