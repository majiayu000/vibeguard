<!-- Generated from docs/directory-guidance.md; do not edit directly. -->

# guards/ directory

Language guard shell scripts are compatibility entrypoints. Detection belongs
in `vibeguard-runtime scan <language> <rule> <path>`; do not add detection,
diff parsing, or fallback scanners to shell.

## Go guards

| Script | Rule ID | Detection content |
|------|---------|----------|
| `guards/go/check_error_handling.sh` | GO-01 | Unchecked error return value assigned to `_` |
| `guards/go/check_goroutine_leak.sh` | GO-02 | Goroutine without an exit mechanism |
| `guards/go/check_defer_in_loop.sh` | GO-08 | Resource-releasing `defer` inside a loop |

## Rust guards

| Script | Rule ID | Detection content |
|------|---------|----------|
| `guards/rust/check_unwrap_in_prod.sh` | RS-03 | `unwrap()` or `expect()` in non-test code |
| `guards/rust/check_duplicate_types.sh` | RS-05 | Types duplicated across crates |
| `guards/rust/check_nested_locks.sh` | RS-01 | Nested locks with deadlock risk |
| `guards/rust/check_workspace_consistency.sh` | RS-06 | Cross-entry path inconsistency |
| `guards/rust/check_single_source_of_truth.sh` | RS-12 | Split task or state sources of truth |
| `guards/rust/check_semantic_effect.sh` | RS-13 | Action semantics and side effects disagree |
| `guards/rust/check_taste_invariants.sh` | TASTE-* | Harness code-taste invariants |
| `guards/rust/check_declaration_execution_gap.sh` | RS-14 | Declared config bypassed at startup |

All language scripts source their local `runtime-shim.sh` and call
`run_runtime_guard`. Each `common.sh` is a deprecated compatibility entrypoint.

RS-03 must exclude independent Rust test files and code below an inline
`#[cfg(test)]` module boundary. Pre-commit mode scans only added diff lines;
standalone audit mode performs a full scan. Intentional non-recoverable uses
require an inline `// vibeguard:allow` comment.

Output format:

```text
[LANG-XX] file:line: problem description. Repair: specific repair method
```
