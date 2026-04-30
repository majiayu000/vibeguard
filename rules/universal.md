# Universal Rules

> Generated from `rules/claude-rules/**` by `python3 scripts/generate_rule_docs.py`. Do not edit by hand.

Reference index for VibeGuard rules that apply across languages, workflows, and repository boundaries.

## Common code and architecture rules

| ID | Rule | Severity | Summary |
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

## Workflow and process rules

| ID | Rule | Severity | Summary |
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
| W-18 | Evaluations must validate path, not only output | Strict | Output-only evaluations miss systemic failures. |

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
