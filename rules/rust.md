# Rust Rules

> Generated from `rules/claude-rules/**` by `python3 scripts/generate_rule_docs.py`. Do not edit by hand.

Reference index for scanning and repairing Rust projects.

## Scan checklist

| ID | Rule | Severity | Summary |
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

## High-value repair patterns

- Merge fragmented state into one `Signal<State>` to avoid nested locking
- Replace `get()` + `insert()` races with the Entry API
- Replace `unwrap()` with `?`, `match`, or `unwrap_or_else`
- Converge logging, config paths, and DB access onto shared helpers
- After struct or enum changes, inspect constructors, serde, DB mappings, fixtures, and snapshots

## Verification command

```bash
cargo fmt && cargo clippy && cargo test --lib
```
