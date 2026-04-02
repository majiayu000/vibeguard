---
name: "VibeGuard: Preflight"
description: "Explore the project before major modifications, generate constraint sets, and prevent problems from the source."
category: VibeGuard
tags: [vibeguard, preflight, constraints, prevention]
---

<!-- VIBEGUARD:PREFLIGHT:START -->
**Core Concept**
- Preventing problems before writing code is 10 times less expensive than detecting and fixing them after writing.
- What is output is a **constraint set** (a list of things that cannot be done), not a pile of information.
- The constraint set guides all subsequent coding, eliminating the need to make architectural decisions during the implementation phase
- Each constraint must be verifiable — either by writing a guard script or by writing a test assertion

**Complexity Routing** (automatically determine process depth)

| Scale | Process | Action |
|------|------|------|
| 1-2 files | Direct implementation | Skip preflight and code directly |
| 3-5 File | Lightweight preflight | Perform steps 1-5 below to generate a constraint set |
| 6+ files | Complete planning | First `/vibeguard:interview` generates SPEC → then execute preflight |

**Trigger Condition** (3+ file levels)
- Changes involving 3+ files
- Added new entry point (binary/service/CLI subcommand)
- Modify the data layer (database, cache, file storage)
- Cross-module refactoring

**Guardrails**
- No code modification, only reading and analysis
- No guessing - Uncertainty is marked as `[UNCLEAR]`, and subsequently confirmed with AskUserQuestion
- The constraint set must be shown to the user for confirmation before coding can begin

**Steps**

1. **Identify project type and structure**
   - Detect languages/frameworks (Cargo.toml → Rust, package.json → TS/JS, pyproject.toml → Python)
   - Recognize monorepo/workspace structure (workspace members/packages/apps)
   - List all entry points (bin crate, main.ts, app.py, CLI commands)
   - Output: `project overview` (list of languages, frameworks, entry points)

2. **Map shared resources**
   - Search all data path constructs (`data_dir`, `db_path`, `config_path`, `.join("xxx.db")`)
   - Search all environment variables read (`env::var`, `process.env`, `os.environ`)
   - Search all port/address bindings (`listen`, `bind`, `PORT`)
   - Identify shared state (global singleton, shared database, message queue)
   - Output: `Shared resource map` (which resources are used by which entrances)

3. **Extract existing schema**
   - Error handling mode (Result vs unwrap, try-catch style)
   - Type definition location (core/ vs each app defines it individually)
   - Naming convention (snake_case/camelCase, prefix rules)
   - Division of module responsibilities (which module is responsible for what)
   - Output: `pattern list`

3.5. **Reference Implementation Search (Skeleton Projects)**
   - Before implementing new functions, first search whether there are similar implementations inside and outside the project for reference.
   - **Search within the project**: Use Grep/Glob to search for keywords, function names, and pattern names to confirm that no existing implementations are missing
   - **Search outside project** (only large changes to 6+ files):
     - Use WebSearch to search for "battle-tested" open source implementations (e.g. `"<feature> implementation" site:github.com`)
     - Evaluate the suitability of candidate implementations (license compatibility, dependencies, maintenance activity)
     - **Not copy**, but extract design decisions as input to constraint sets
   - Output: `Reference Implementation List`
     ```
     [REF-01] In the project: src/core/xxx.ts already has similar XX logic and should be extended rather than newly created.
     [REF-02] Outside the project: The ZZ mode at github.com/xxx/yyy is worthy of reference (MIT, 1.2k stars, actively maintained)
     [REF-NONE] No reference implementation found, need to design from scratch
     ```
   - If an existing implementation is found in the project → Generate L1 constraint: "Extend [REF-XX] instead of creating a new one"

3.6. **Directory semantic verification**
   - List all subdirectory names of the project (first level + second level), and compare the built-in semantic mapping table to determine the consistency of responsibilities:

     | Directory Name | Expected Responsibilities |
     |--------|----------|
     | middleware | Request interception / middleware logic |
     | schemas | model definition / data validation |
     | models | ORM / data model |
     | services | business logic |
     | utils/helpers | Pure function tools |
     | routes/api | route definition/endpoint handling |
     | controllers | Request processing/scheduling |
     | core | core logic / shared interface |
     | config | configuration loading |
     | commands | CLI command definition |

   - For directories that hit the mapping table, randomly check the top-level class/function names (the first 3 files) to determine whether they are consistent with the directory semantics.
   - SKIP: Directories with the number of files < 3, `tests/`, `migrations/`, `__pycache__/`, directories that miss the mapping table
   - Output PASS/WARN report:
     ```
     [DIR-SEMANTIC] schemas/ — PASS (3/3 files contain Schema/Model definition)
     [DIR-SEMANTIC] utils/ — WARN (utils/db_manager.py contains class DBManager, which is suspected to be business logic rather than pure functions)
     ```
   - WARN item automatically generates constraints in Step 5: `[C-XX] utils/ only stores pure functions without side effects, DBManager should be moved to services/`

4. **Run static guard to obtain baseline**
   - Select the corresponding vibeguard guard script according to the language:
     - **Rust**: `check_unwrap_in_prod.sh`, `check_duplicate_types.sh`, `check_nested_locks.sh`, `check_workspace_consistency.sh`
     - **Python**: `check_duplicates.py`, `check_naming_convention.py`, `test_code_quality_guards.py`
     - **TypeScript**: `check_any_abuse.sh`, `check_console_residual.sh`
   - Record the current number of violations as a baseline (cannot be increased after modification)
   - Output: `Guard Baseline`

   **[Stop] Displays baseline data and waits for user confirmation before generating a constraint set. **
   - Show all findings from steps 1-4
   - Use AskUserQuestion to let users confirm that baseline data and project understanding are correct
   - If there is a `[UNCLEAR]` item, it must be confirmed with an AskUserQuestion here

5. **Generate constraint set**

   First run the constraint recommender to generate an initial draft (`python3 ${VIBEGUARD_DIR:-vibeguard}/scripts/constraint-recommender.py <project_dir>`), then supplement and adjust it based on findings from steps 1-4. The recommender outputs three confidence levels: high (automatically accepted) / medium (prompt for confirmation) / low (needs discussion).

   Based on the findings from steps 1-4 and the first draft of the recommender, generate a constraint set for the current task. Format of each constraint:

   ```
   [C-XX] Constraint description
   Source: Concrete evidence found in Step N
   Verification: How to check for violations (guard script/test/manual inspection)
   ```

   **Constraint categories that must be covered**:

   | Category | Constraint Goal | Example |
   |------|----------|------|
   | Data convergence | The data paths of all entries must be converged | "All entries obtain the DB path through `core::resolve_db_path()`" |
   | Unique type | Do not add definitions with the same name as existing types | "It is prohibited to redefine core's existing SearchQuery at the app layer" |
   | The interface is stable | Does not break the public API signature | "ItemId::from(&str) signature remains unchanged" |
   | Error handling | Maintain an error handling style consistent with the project | "Unwrap() is prohibited in non-test code, use ? or map_err" |
   | Consistent naming | Follow the existing naming convention of the project | "Environment variables uniformly use the REFINE_ prefix" |
   | Guard the baseline | The number of violations will not increase after modification | "Unwrap number ≤ 50, repeat type ≤ 2" |

6. **Output constraint set report**

   Output the constraint set in a structured format:

   ```markdown
   # VibeGuard Preflight constraint set

   ## Project: <project name>
   ## Task: <user-described task>
   ## Date: <current date>

   ## Constraint list

   ### Data convergence
   - [C-01] ...

   ### Unique type
   - [C-02] ...

   ### Guard the baseline
   - [C-XX] Baseline before modification: unwrap=50, duplicates=2, nested_locks=0
     After modification, it must be: unwrap ≤ 50, duplicates ≤ 2, nested_locks = 0

   ## Questions that require user confirmation
   - [UNCLEAR] ...
   ```

7. **User Confirmation**
   - Show the complete constraint set
   - Confirm `[UNCLEAR]` item with AskUserQuestion
   - After user confirmation, the constraints are integrated into hard constraints for subsequent coding

**Follow-up use**
- During the coding process, self-check against the constraint set before each modification
- After encoding is complete, run `/vibeguard:check` to verify that the guard baseline has not deteriorated
- Every rule in the constraint set cannot be violated - if it is violated, the constraint set must be updated and the user consent must be obtained first

**Reference**
- VibeGuard guard script: `vibeguard/guards/`
- VibeGuard rules: `vibeguard/rules/`
- VibeGuard seven-layer anti-hallucination framework: `docs/how/learning-skill-generation.md`
<!-- VIBEGUARD:PREFLIGHT:END -->
