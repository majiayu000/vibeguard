# Rust Rules (Rust specific rules)

Specific rules for scanning and repairing Rust projects. Extracted from practical experience of 30+ sessions in rnk project.

## Scan check items

| ID | Category | Check Item | Severity |
|----|------|--------|--------|
| RS-01 | Bug | Nested RwLock/Mutex acquisitions (deadlock risk) | High |
| RS-02 | Bug | TOCTOU: get() followed by insert(), the lock was released in the middle | High |
| RS-03 | Bug | unwrap() in non-test code (panic risk) | Medium |
| RS-04 | Design | Multiple Signal/Arcs managing the same logic state (should be combined into a single) | Medium |
| RS-05 | Design | Types with the same name but different synonyms (such as two RenderHandles) | Medium |
| RS-06 | Dedup | Same match arm repeated in multiple methods | Medium |
| RS-07 | Dedup | Manual field-by-field copy (apply merge/apply method) | Low |
| RS-08 | Perf | Unnecessary clone() (use clone for Copy type, clone for borrow type) | Low |
| RS-09 | Perf | format!() allocation in hot path (can use push_str or preallocation) | Low |
| RS-10 | Bug | Silently discard meaningful Result/Error (`let _ =`, `.ok()`, `.unwrap_or_default()` swallow errors) | High |
| RS-11 | Design | Different modules of the same project use different infrastructure (logging system, configuration path, DB connection method) | Medium |
| RS-12 | Design | Dual systems coexist for the same responsibility (such as Todo* and TaskManagement* dual tracks) | High |
| RS-13 | Design | Action semantic functions (done/update/delete, etc.) lack visible state side effects | High |

## SKIP rules (Rust specific)

| Conditions | Judgment | Reasons |
|------|------|------|
| Use std::thread but cleanup needs to be synchronized | SKIP | use_effect cleanup is FnOnce + Send, cannot use async |
| Signal<T> clone looks like "copy" | SKIP | Signal is Arc<RwLock>, clone shares state, not clones |
| Set hooks have similar patterns (list/set/map) | SKIP | Each has domain-specific methods, macros are over-engineering |
| derive(Clone) seems redundant | check | Signal<T> requires T: Clone |
| #[allow(dead_code)] | Check | Possibly a WIP feature, marked DEFER instead of DELETE |

## Repair mode (verified to be effective)

### Multiple Signal → Single Signal
```rust
// Before: 3 Signals, risk of nested locks
struct History<T> {
    past: Signal<Vec<T>>,
    present: Signal<T>,
    future: Signal<Vec<T>>,
}

// After: single Signal, atomic operation
struct History<T> {
    state: Signal<HistoryState<T>>,
}
struct HistoryState<T> { past: Vec<T>, present: T, future: Vec<T> }
// All operations are completed at once using state.update(|s| { ... })
```

### TOCTOU → entry API
```rust
// Before: get() insert() after releasing the lock
if !map.get(&key).is_some() { map.insert(key, val); }

// After: single update + entry
signal.update(|m| { m.entry(key).or_insert(val); });
```

### Repeat match → parameterize
```rust
// Before: 18 match arms each for to_ansi_fg() and to_ansi_bg()
// After: to_ansi(self, background: bool) share a match
fn to_ansi(self, background: bool) -> String {
    let base: u8 = if background { 40 } else { 30 };
    match self { Color::Red => format!("\x1b[{}m", base + 1), ... }
}
```

### Repeating type → Extract shared module
```rust
// Before: textarea/keymap.rs and viewport/keymap.rs each define KeyBinding, KeyType, Modifiers
// After: components/keymap.rs is defined once and pub use is introduced twice.
pub use crate::components::keymap::{KeyBinding, KeyType, Modifiers};
```

### Silent error discarding → explicit handling (RS-10)

`let _ =`, `.ok()`, `.unwrap_or_default()` make the error message disappear permanently when discarding `Result<T, E>`.
The code will not panic, but the data will be lost, the log will become a black hole, and the problem will not be troubleshooted.

```rust
// BAD: Errors are silently discarded
let _ = db::update_last_accessed(&conn, &ids);
let body = resp.text().await.unwrap_or_default();
let path = std::fs::canonicalize(&abs).unwrap_or(abs);

// GOOD: At least log errors
if let Err(e) = db::update_last_accessed(&conn, &ids) {
    log::warn("mcp", &format!("update_last_accessed failed: {}", e));
}
let body = resp.text().await.unwrap_or_else(|e| format!("<body read error: {}>", e));
let path = std::fs::canonicalize(&abs).unwrap_or_else(|e| {
    log::warn("db", &format!("canonicalize failed: {}", e));
    abs
});
```

**Judgment Rules**:
- `let _ = expr` and expr returns `Result` → **must be processed**
- `.ok()` discards Error and no subsequent fallback log → **must be processed**
- `.unwrap_or_default()` and the default value will cause data exceptions (empty string storage, path splitting) → **must be processed**
- `.unwrap_or_default()` and the default is a safe no-op (like `Vec::new()`) → SKIP

### Cross-module infrastructure consistency (RS-11)

All entries (CLI subcommands, MCP server, hooks, worker subprocesses) of the same project must share:
- **Log system**: write the same file or the same output uniformly
- **DB connection strategy**: long-lived processes reuse connections, short-lived processes are created on demand
- **Configuration path**: `db_path()`, `log_path()`, etc. are only defined once

```rust
// BAD: MCP uses tracing to write stderr, hooks uses custom log to write files
// There is no log when MCP fails, a complete black hole
tracing_subscriber::fmt().with_writer(std::io::stderr).init();

// GOOD: All entries share the same log function
crate::log::info("mcp", "server started");
```

### Single Source of Truth Convergence (RS-12)

The same responsibility (especially task management) should not maintain two tool families and two state stores in parallel.

```rust
// BAD: Todo* + TaskManagement* coexist, each writing different states
registry.register(TodoWrite);
registry.register(TaskDone);

// GOOD: Convergence to a single task domain interface
registry.register(TaskWrite);
registry.register(TaskRead);
// All actions only write TaskRepository
```

### Semantic Side Effect Consistency (RS-13)

Action semantic functions (`mark_done` / `update_*` / `delete_*`) must have visible side effects:
- Write status (insert/update/remove)
- or emit events (emit/dispatch/send)

```rust
// BAD: only returns text, no status
fn mark_done(id: &str) -> Result<String> {
    Ok(format!("task {} done", id))
}

// GOOD: Drop the state first, then return the result
fn mark_done(id: &str, repo: &TaskRepo) -> Result<String> {
    repo.update_status(id, Status::Done)?;
    Ok(format!("task {} done", id))
}
```

## Verification command
```bash
cargo fmt && cargo clippy && cargo test --lib
```
Each fix must be run after completion. clippy warning is considered a failure.
