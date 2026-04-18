# Rust Rules

Reference index for scanning and repairing Rust projects.

## Scan checklist

| ID | Category | Check item | Severity |
|----|------|--------|--------|
| RS-01 | Concurrency | Nested `RwLock` / `Mutex` acquisition | High |
| RS-02 | Concurrency | TOCTOU: `get()` followed by `insert()` | High |
| RS-03 | Correctness | `unwrap()` in non-test code | Medium |
| RS-04 | Design | Multiple `Signal` / `Arc` objects manage one logical state | Medium |
| RS-05 | Design | Same name, different meaning type duplication | Medium |
| RS-06 | Dedup | Match arms duplicated across methods | Medium |
| RS-07 | Dedup | Manual field-by-field copying | Low |
| RS-08 | Perf | Unnecessary `clone()` | Low |
| RS-09 | Perf | `format!()` allocation in hot paths | Low |
| RS-10 | Correctness | Meaningful `Result` values are silently discarded | High |
| RS-11 | Architecture | Different modules use inconsistent infrastructure | Medium |
| RS-12 | Architecture | Dual systems coexist for one responsibility | High |
| RS-13 | Design | Action-named functions do not mutate state or emit events | High |
| RS-14 | Architecture | Declaration-execution gap | High |
| RS-20 | Change safety | Struct field / enum variant changes are not checked end-to-end | Strict |
| TASTE-ANSI | Style | Hardcoded ANSI escape sequences | Medium |
| TASTE-ASYNC-UNWRAP | Style | `.unwrap()` inside `async fn` | Medium |
| TASTE-PANIC-MSG | Style | `panic!()` lacks a meaningful message | Medium |

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
