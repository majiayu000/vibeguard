# guards/rust/ directory

Rust language guard script to perform static pattern detection on Rust projects.

## Script list

| Script | Rule ID | Detection Content |
|------|---------|----------|
| `check_unwrap_in_prod.sh` | RS-03 | unwrap()/expect() in non-test code |
| `check_duplicate_types.sh` | RS-05 | Duplicately defined types across crates |
| `check_nested_locks.sh` | RS-01 | Nested locks (potential deadlock) |
| `check_workspace_consistency.sh` | RS-06 | Cross-entry path consistency |
| `check_single_source_of_truth.sh` | RS-12 | Task system dual-track coexistence/multi-state source splitting |
| `check_semantic_effect.sh` | RS-13 | Action semantics and side effects are inconsistent |
| `check_taste_invariants.sh` | TASTE-* | Harness style code taste constraints (ANSI hardcoded, async unwrap, panic no message) |

## common.sh usage

All scripts introduce shared functions through `source common.sh`:
- `list_rs_files <dir>` — List .rs files (prefer git ls-files)
- `parse_guard_args "$@"` — parses --strict and target_dir
- `create_tmpfile` — Create an automatically cleaned temporary file

## Output format

```
[RS-XX] file:line problem description. Repair: specific repair methods
```

## RS-03 Test Code Exclusion Strategy

The exclusion for RS-03 (unwrap in prod) must cover Rust's three test code locations:

1. **Independent test files**: `tests/*.rs`, `tests.rs`, `test_helpers.rs` - exclude by path grep
2. **inline test module**: `#[cfg(test)] mod tests { ... }` at the end of the prod file - excluded by `#[cfg(test)]` line number demarcation (all unwrap after this line is regarded as test code)
3. **Reasonable use of expect**: non-recoverable scenarios such as signal handler and main entrance - whitelist through `// vibeguard:allow` inline comments

**Design Decisions**:
- **Pre-commit mode only scans new lines in diff** - does not block existing code, only intercepts this new unwrap. This is the core design: the guard’s responsibility is to prevent new risks, not to trace historical debts
- **Standalone mode maintains full scan** — for manual auditing (`/vibeguard:check`), reporting the full picture

**lesson**:
- Line-by-line `grep -v '#[cfg(test)]'' only excludes the line itself containing the tag, not the code within its scope - this was the root cause of the original 155 false positives
- Filename `tests.rs` does not match `_test\.rs$` pattern — Rust uses `tests.rs` not `_test.rs`
- Signal handler's `expect()` is a reasonable use: crashing in the event of an OS-level failure is safer than continuing silently
- **Full scan for pre-commit is wrong** - All 155 existing unwraps in the upstream will be intercepted, causing no commit to pass. Guard should only care about "the code you just wrote"
