# Universal Rules

Scan and repair rules for all languages.

## NEVER rule (absolutely don’t do it)

| ID | Rule | Reason |
|----|------|------|
| U-01 | Do not modify public API signatures | Unless the user explicitly requests breaking change and accepts MAJOR version upgrades |
| U-02 | Not extracting abstractions for code that only occurs once | Over-engineering, 3 lines of duplication are better than 1 premature abstraction |
| U-03 | Don't use macros to replace readable repeated code | Macros reduce readability and IDE support unless there are > 5 repetitions and the pattern is exactly the same |
| U-04 | Do not add unrequested functionality | Bug fixes without refactoring surrounding code |
| U-05 | Not deleting code that looks "useless" without first confirming | It may be a feature being developed by the user |
| U-06 | Not introducing new dependencies to solve problems that can be solved with the standard library | Dependency bloat |
| U-07 | Do not change code style in a fix | Style changes should be independent commits |
| U-08 | Do not skip verification steps | Each fix must pass lint + test independently |
| U-09 | Don’t commit multiple unrelated fixes at once | Atomic commit, convenient for revert |
| U-10 | Don’t guess user intent | Mark DEFER if unsure |

## Cross-entry consistency check

When multiple binaries share data sources in a Monorepo/workspace, configuration convergence must be checked.

| ID | Category | Check Item | Severity |
|----|------|--------|--------|
| U-11 | Data | Multi-binary default DB/cache paths are inconsistent (data splitting) | High |
| U-12 | Data | Fallback path for shared data source creates wrong file on first use | High |
| U-13 | Config | The environment variable names of multiple entries are not uniform (such as `SERVER_DB_PATH` vs `DESKTOP_DB_PATH` pointing to different default values) | Medium |
| U-14 | Config | CLI default path is different from GUI/Server default path base directory | Medium |

### Scanning method

1. Search all `get_db_path` / `db_path` / `default_value` / `data_dir` and other data source path constructors in the workspace
2. Compare the default values of each binary to see if they converge to the same physical path.
3. Check whether the fallback logic will create split files under a specific boot sequence

### Typical case (refine project)

```
Server: ~/.local/share/refine/server.db ← Always write here
Desktop: ~/.local/share/refine/server.db ← only if the file already exists
         ~/.local/share/refine/data.db ← fallback, first startup creation
CLI: ~/.refine/data.db ← Completely different base directory
```

The user first starts Desktop → creates `data.db` → then starts Server → creates `server.db` → data is split, and Desktop reads the old database and displays it as empty.

### Repair mode

```
// Before: Each entry is hard-coded.
fn get_db_path() -> PathBuf { base.join("server.db") }  // server
fn get_db_path() -> PathBuf { base.join("data.db") }    // desktop fallback
#[arg(default_value = "~/.refine/data.db")]              // CLI

// After: unified to core public functions
pub fn default_db_path() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("refine")
        .join("refine.db")
}
// All entries call core::default_db_path(), and the environment variables are unified to REFINE_DB_PATH
```

## FIX/SKIP judgment matrix

| Condition | Judgment |
|------|------|
| Logic bugs (deadlock, TOCTOU, panic) | FIX - high priority |
| Inconsistency in multiple binary data paths leads to data splitting | FIX — high priority |
| Duplicate code > 20 lines with identical semantics | FIX — Medium priority |
| Code duplication but different semantics (such as similar methods in different components) | SKIP — different semantics |
| Naming conflict (types with the same name but different synonyms) | FIX — medium priority |
| The names of multiple entry environment variables are not uniform (if the user only configures one, it will be split) | FIX - medium priority |
| Silent fallback of configuration is not supported | FIX - high priority |
| Performance issues but not in the hot path | SKIP — insufficient gain |
| Performance issues in hot paths (rendering loop, event handling) | FIX — Medium priority |
| Lack of tests but stable code | DEFER — low priority |
| Missing tests and the code has known bugs | FIX — high priority |
| Stylistically inconsistent but functionally correct | SKIP — independent processing |
| Touches > 50% of files | DEFER — Requires user confirmation of scope |

## Engineering Practice Rules

| ID | Rule | Description |
|----|------|------|
| U-15 | Immutability first | Create new objects rather than modify existing ones; function parameters are treated as read-only |
| U-16 | File size control | 200-400 lines typical, 800 lines maximum; more than 800 lines must be split |
| U-17 | Complete error handling | Comprehensively handle error paths and provide user-friendly error messages; do not swallow exceptions silently |
| U-18 | Input Validation | Validate all user input at system boundaries; internal code trust framework guarantees |
| U-19 | Repository pattern | Data access is encapsulated into the Repository layer; business logic does not directly operate the database |
| U-20 | API response format | Unified envelope structure `{ data, error, meta }`; error code standardization |
| U-21 | Commit message format | `<type>: <description>`, type is feat/fix/refactor/docs/test/chore |
| U-22 | Test Coverage | Minimum 80% line coverage for new code; 100% critical path |
| U-23 | Silent downgrade is prohibited | Unsupported policies/configurations must explicitly report an error or mark DEFER, and must not automatically downgrade to the default policy |
| U-24 | Any aliases are prohibited | Function/type/command/directory aliases and compatible naming are prohibited; old names should be directly replaced in full and deleted if old names are found |

## Scanning strategy

### Parallel scan
Partitioned by module, each sub-agent is responsible for one module:
- Core modules (type definitions, infrastructure)
- Business logic (hooks, components, commands)
- Rendering/output (renderer, layout, output buffer)
- Testing/Tools (testing frameworks, examples, benchmarks)

### Remove duplicate questions
Multiple manifestations of the same root cause are recorded only once, marking all affected files.

### Dependency sorting
Repair sequence: bug fix → type/naming → code deduplication → performance → testing
Within the same level, they are arranged from small to large in terms of scope of influence (prerequisite for isolation).
