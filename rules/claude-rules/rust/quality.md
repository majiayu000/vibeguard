---
paths: **/*.rs,**/Cargo.toml,**/Cargo.lock
---

# Rust Quality Rules

## RS-01: Nested RwLock/Mutex Get (High)
Holding multiple locks at the same time leads to deadlock. Fix: Merge multiple Signals into a single `Signal<State>`, using `.update()` atomic operation.

## RS-02: TOCTOU — get() followed by insert() (high)
The lock is released in the middle causing a race condition. Fix: Use Entry API `m.entry(key).or_insert(val)` instead for single locking.

## RS-03: unwrap() in non-test code (center)
panic risk. Fix: Replaced with `?` spread, `.unwrap_or_else()` or explicit match.

## RS-04: Multiple Signal/Arcs manage the same logical state (medium)
Should be combined into a single `Signal<State>` structure and all fields managed centrally.

## RS-05: Types with the same name but different synonyms (medium)
Such as two `RenderHandle`. Fix: Extract to shared module and import the rest with `pub use`.

## RS-06: Same match arm repeated in multiple methods (center)
Fix: Parameterize into a single function, differentiate branches by parameters.

## RS-07: Manual field-by-field copy (low)
Apply the merge/apply method. Fix: Implement the `apply` method or the `Update` trait.

## RS-08: Unnecessary clone() (low)
Copy type or borrowable scene. Fix: Remove clone from Copy type; use borrowing instead of passing by reference.

## RS-09: format!() allocation in hot path (low)
Fix: Use `push_str`, pre-allocated `String::with_capacity()` or `write!` instead.

## RS-10: Silently discard meaningful Result (high)
`let _ =`, `.ok()`, `.unwrap_or_default()` swallow errors. Fix: Use `if let Err(e)` to at least log.
```rust
// Bad: let _ = db::update(&conn, &ids);
// Good:
if let Err(e) = db::update(&conn, &ids) {
    log::warn("update failed: {}", e);
}
```

## RS-11: Different modules use different infrastructure (medium)
The log system, configuration path, and DB connection method are inconsistent. Fix: Unify shared functions to core.

## RS-12: Coexistence of dual systems with the same responsibility (high)
Such as Todo* and TaskManagement* dual tracks. Fix: Convergence to single domain interface, removing redundancy.

## RS-13: Action semantic functions lack state side effects (high)
`mark_done` only returns the text not falling state. Fix: Functions must write status (insert/update/remove) or emit events.

## RS-14: Statement-Execution Gap (High)
Config/Trait/Persistence layer declared but not integrated at startup. Fixes: Audit claim points, verify launch registration, add missing calls.

**Detection Mode**:
- Config structure exists but startup calls `Default::default()`
- Trait declared but without `impl` or not registered in registry
- `fn save/load/persist` exists but is never called on startup
- Field added to struct but constructor not initialized

**fix list**:
```rust
// Bad: Config declared but not loaded
let config = MyConfig::default(); // Configuration file is ignored

// Good: Explicitly loaded at startup
let config = MyConfig::load_from_file("config.toml")
    .unwrap_or_else(|_| MyConfig::default());  // silent fallback

// Bad: persistence method exists but is never called
impl Store {
    fn restore(&mut self) { /* Restore from DB */ }
}
// Startup code: let store = Store::new(); // restore() is never called

// Good: Restore state on startup
let mut store = Store::new();
store.restore()?; // Explicit restore
```

## TASTE-ANSI: Hardcoded ANSI escape sequence
The colored/termcolor crate should be used instead of `\x1b[` hardcoding.

## TASTE-ASYNC-UNWRAP: async fn within .unwrap()
async contexts should use the `?` operator to propagate errors rather than unwrap causing panic.

## TASTE-PANIC-MSG: panic!() lacks meaningful message
`panic!()` or `panic!("")` is missing context. Fix: Add descriptive message explaining cause of panic.
