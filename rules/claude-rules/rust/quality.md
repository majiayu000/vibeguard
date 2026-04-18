---
paths: **/*.rs,**/Cargo.toml,**/Cargo.lock
---

# Rust Quality Rules

## RS-01: Nested `RwLock` / `Mutex` acquisition (high)
Holding multiple locks at once creates deadlock risk. Fix: merge the state into one `Signal<State>` and update it atomically with `.update()`.

## RS-02: TOCTOU — `get()` followed by `insert()` (high)
The lock is released between read and write, which creates a race. Fix: use the Entry API (`m.entry(key).or_insert(val)`) under a single lock.

## RS-03: `unwrap()` in non-test code (medium)
`unwrap()` creates panic risk. Fix: replace it with `?`, `.unwrap_or_else()`, or an explicit `match`.

## RS-04: Multiple `Signal` / `Arc` objects manage the same logical state (medium)
Converge them into a single `Signal<State>` so one structure owns the whole state.

## RS-05: Same name, different meaning types (medium)
For example, two different `RenderHandle` types. Fix: extract the canonical type into a shared module and import it everywhere else with `pub use`.

## RS-06: The same match arm is duplicated across multiple methods (medium)
Fix: factor it into one parameterized function that distinguishes behavior through arguments.

## RS-07: Manual field-by-field copying (low)
Use merge or apply methods instead. Fix: add an `apply` method or an `Update` trait.

## RS-08: Unnecessary `clone()` calls (low)
Often appears on `Copy` types or values that could be borrowed. Fix: remove `clone()` for `Copy` data or pass references instead.

## RS-09: `format!()` allocation in hot paths (low)
Fix: use `push_str`, preallocate with `String::with_capacity()`, or use `write!`.

## RS-10: Meaningful `Result`s are silently discarded (high)
Patterns like `let _ =`, `.ok()`, or `.unwrap_or_default()` swallow errors. Fix: at minimum handle `Err` explicitly and log it.
```rust
// Bad: let _ = db::update(&conn, &ids);
// Good:
if let Err(e) = db::update(&conn, &ids) {
    log::warn("update failed: {}", e);
}
```

## RS-11: Different modules use different infrastructure for the same system (medium)
Logging, config paths, or DB connection strategies drift across modules. Fix: converge on shared core helpers.

## RS-12: Two systems coexist for one responsibility (high)
For example, `Todo*` and `TaskManagement*` both handle task state. Fix: converge on a single domain interface and delete the redundant track.

## RS-13: Action-named functions lack state side effects (high)
A function like `mark_done` only returns text but does not persist state. Fix: the function must write state (`insert`, `update`, `remove`) or emit an event.

## RS-14: Declaration-execution gap (high)
Configs, traits, or persistence layers are declared but never integrated into startup. Fix: audit declaration sites, verify startup registration, and add the missing wiring.

**Detection patterns**:
- A config struct exists but startup still calls `Default::default()`
- A trait is declared but has no `impl` or never gets registered
- `save`, `load`, or `persist` methods exist but startup never calls them
- A field is added to a struct but constructors never initialize it

**Repair checklist**:
```rust
// Bad: config exists but is never loaded
let config = MyConfig::default();  // config file ignored

// Good: explicit load during startup
let config = MyConfig::load_from_file("config.toml")
    .unwrap_or_else(|_| MyConfig::default());  // intentional fallback

// Bad: persistence method exists but is never called
impl Store {
    fn restore(&mut self) { /* restore from DB */ }
}
// Startup code: let store = Store::new();  // restore() never runs

// Good: restore at startup
let mut store = Store::new();
store.restore()?;
```

## TASTE-ANSI: Hardcoded ANSI escape sequences (medium)
Use a crate like `colored` or `termcolor` instead of hardcoding `\x1b[` sequences.

## TASTE-ASYNC-UNWRAP: `.unwrap()` inside `async fn` (medium)
Async code should propagate errors with `?` instead of panicking with `unwrap()`.

## TASTE-PANIC-MSG: `panic!()` without a meaningful message (medium)
`panic!()` or `panic!("")` lacks context. Fix: provide a descriptive message that explains why the panic is intentional.
