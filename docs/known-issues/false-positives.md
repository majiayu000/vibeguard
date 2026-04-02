# Known False Positives

Known false positive scenarios and fix status for Guard and Hook. **A must-read when developing Agent** to avoid repeated pitfalls.

## Fixed

### TS-03: CLI project console false positive
- **Scenario**: `console.log/error` of CLI tool (package.json contains `bin` field) is normal output, not debugging residue
- **Impact**: All CLI projects are blocked
- **Fix**: guard and post-edit hook detect the `bin` field of `package.json`, CLI project skips console detection
- **Files**: `guards/typescript/check_console_residual.sh`, `hooks/post-edit-guard.sh`

### RS-14: Statement-Perform Gap Detection (rewritten with ast-grep)
- **Scenario**: The original 4 sub-detections all have serious false positives (grep line count, external crate trait, save/load only checks the main file, cd changes cwd)
- **FIX**: Rewrite with ast-grep AST level scan, focusing on the highest value single detection: `*Config::default()` calls (instead of `Config::load()`)
  - Exactly match `AppConfig::default()`, `ServerConfig::default()` and other patterns (through `constraints.T.regex: "Config$"`, double verification in yml and Python post-processing layer)
  - Automatically exclude test file directories (`/tests/`, `_test.rs`, etc.)
  - Skip gracefully when ast-grep is not available (`[RS-14] SKIP`)
- **Current scope**: Only detects `*Config::default()` mode; Trait has no impl, persistence is not wired and other complex cross-file detection requires heavier tools such as rust-analyzer
- **Files**: `guards/rust/check_declaration_execution_gap.sh`, `guards/ast-grep-rules/rs-14-config-default.yml`

### GO-02: goroutine full enumeration
- **Scenario**: All `go func()` reports, regardless of ctx/wg/errgroup management
- **Impact**: Any Go project using goroutines will be extremely noisy
- **Fix**: Add heuristic filtering, skip `ctx.Done/wg.Add/errgroup/ticker` within 20 lines after goroutine
- **File**: `guards/go/check_goroutine_leak.sh`

### TS-01: any detection misses hits on comments and strings (fixed with ast-grep)
- **Scenario**: `: any` inside block comment `/* type: any */` and string `"schema: any"` is falsely reported
- **Impact**: False positives for TS files containing comments or string descriptions
- **Fix**: Use ast-grep AST level detection instead, match `type_annotation` nodes and `as any` expressions, automatically skip comments/strings
- **Files**: `guards/typescript/check_any_abuse.sh`, `guards/ast-grep-rules/ts-01-any.yml`

### GO-01: false positive for range variable (fixed with ast-grep)
- **Scenario**: `_` in `for _, v := range slice` is discarded as an error
- **AFFECT**: All Go files using range
- **Fix**: Use ast-grep to match the `_ = $CALL` pattern instead. AST naturally distinguishes assignment statements and for range clauses without manual exclusion.
- **Files**: `guards/go/check_error_handling.sh`, `guards/ast-grep-rules/go-01-error.yml`

### TS-13: Component duplicate features are too wide
- **Scenario**:
  1. FormField detection: HTML native `<input required>` mistakenly hit
  2. Sorting table: API parameter `sortKey` hit by mistake
  3. Query Hook: Standard `isLoading` state management mishit
- **Fix**: Tighten required to prop level (`isRequired/props.required`), sort limit `setSortKey`, query threshold 3→4
- **File**: `guards/typescript/check_component_duplication.sh`

### U-HARDCODE: Hardcoded value detection (removed)
- **Scenario**: `= "POST"`, enumeration assignment, React props, i18n key, constant definition all false positives
- **Impact**: Almost all TS/JS files
- **Fix**: Remove this detection from post-edit-guard (unacceptable signal-to-noise ratio)
- **File**: `hooks/post-edit-guard.sh`

### pre-bash: git checkout ./path blocked by mistake
- **Scenario**: `git checkout ./src/file.ts` is intercepted as `git checkout .` (discarding all changes)
- **Fix**: Regular plus end-of-line anchoring, only matches pure `.` followed by delimiter or end of line
- **File**: `hooks/pre-bash-guard.sh`

### pre-commit: subdirectory commit language detection failed
- **Scenario**: When executing `git commit` in a subdirectory, `[[ -f "Cargo.toml" ]]` fails to detect relative paths and all guards are skipped
- **Fix**: Use `${REPO_ROOT}/Cargo.toml` absolute path instead
- **File**: `hooks/pre-commit-guard.sh`

### post-edit: Escalation is triggered by mistake across sessions
- **Scenario**: The warn count does not differentiate between sessions. I was warned 3 times last week → escalated after my first edit today.
- **Fix**: Add session filtering + exact path matching (to avoid misjudgment of sub-paths)
- **File**: `hooks/post-edit-guard.sh`

## Fixed (P2, fix #28)

The following issues have been fixed in PR #28:

| Guard | Scene | Repair Method |
|------|------|----------|
| RS-03 | Multiple `#[cfg(test)]` blocks only take the first one | Use awk to trace test mod scope (brace depth) instead, support multiple `#[cfg(test)]` blocks |
| RS-01 | `.clone()` incorrectly reduces the lock count, `}` unconditionally decrements the count | Remove the `.clone()` heuristic; use brace_depth tracking when lock acquisition instead, `}` only releases the lock at the current depth when closed |
| RS-06 | Hardcoded path detection false positives for string constants (`"config.toml"`) | Add comment lines and `const`/`static` definition exclusions to avoid false positives for string constants |
| RS-12 | `Todo[A-Z]` matches common TodoList data structures | Exactly limited to Claude Code-specific tool names `TodoWrite`/`TodoRead`, excluding common data structure names |
| TASTE-ASYNC-UNWRAP | If there are any async fn in the file, all unwrap will be reported | Use awk to track the async fn function body scope instead, and only report the unwrap inside the async fn |
| post-write | Search for files with the same name hits the tests/ directory | Add `tests/`, `__tests__/`, `test/`, `spec/` to both rg and find paths to exclude |
| post-write | Define extraction regular cross-language pollution | Select language-specific regular rules according to file extensions (rs/ts/py/go) to eliminate cross-language pattern pollution |
| post-build | Build failure count across projects without isolation | escalation count increment `PROJECT_ROOT` filter, only accumulate the number of failures in the same project |
| doc-file-blocker | `.md` detects misjudgment of temporary file paths | Add `/tmp/`, `/var/`, `$TMPDIR` and other temporary paths to the whitelist to skip temporary files |

## Lessons

1. **grep is not an AST parser** — grep has an unacceptable false positive rate for code with nested structures (lock scopes, async function scopes, struct fields). Complex detection should use language tools (rust-analyzer, ESLint, go vet)
2. **The guard's bug fix suggestions will be taken seriously by the Agent** — TS-03 said "use the project logger instead", and the Agent actually created the logger and reconstructed 11 files. Guard messages must consider Agent consumption scenarios
3. **Project type awareness is the basic ability** - CLI vs Web vs MCP vs Library, different project types in the same language have completely different reasonable patterns. Guard must first identify the item type
4. **Enumerator is not a detector** — GO-02 previously only listed all goroutines without judging whether there were risks. Developers (and Agents) will develop a habit of neglect and lose the value of guarding
