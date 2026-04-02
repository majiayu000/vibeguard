# [Project Name] — Claude Code Guidelines

## Project Overview

[Project Brief]

| Component | Location | Tech Stack |
|-----------|----------|------------|
| Core | `src/` | Rust |

---

## Critical Rules

### 1. NO BACKWARD COMPATIBILITY

Just delete the old code.

```rust
// ❌ BAD
#[deprecated(note = "Use new_function instead")]
pub fn old_function() { new_function() }

// ✅ GOOD - delete directly, update all callers
```

### 2. NO DEAD CODE

Do not leave out `#[allow(dead_code)]`.

```rust
// ❌ BAD
#[allow(dead_code)]
fn unused_helper() { ... }

// ✅ GOOD - delete directly
```

### 3. NO HARDCODING

Configuration values come from environment variables or configuration files.

```rust
// ❌ BAD
let port = 8080;

// ✅ GOOD
let port = config.port;
```

### 4. NAMING CONVENTION

- Type/Trait: PascalCase(`HttpClient`)
- Function/Variable: snake_case(`get_user`)
- Constant: UPPER_SNAKE_CASE(`MAX_RETRIES`)
- module/file: snake_case (`http_client.rs`)

### 5. SEARCH BEFORE CREATE

You must search before creating a new struct/trait/function.

```bash
rg "pub (struct|enum|trait) <Name>" src/
rg "pub fn <name>" src/
```

### 6. ERROR HANDLING

Use specific error types and don't abuse `.unwrap()`.

```rust
// ❌ BAD
let value = map.get("key").unwrap();

// ✅ GOOD
let value = map.get("key").ok_or(AppError::KeyNotFound("key"))?;
```

---

## Architecture

```
src/
├── main.rs
├── lib.rs
├── config/ # Configuration
├── core/ # core area
│   ├── models/
│   └── traits/
├── services/ # Business logic
├── adapters/ # External adaptation
│   ├── http/
│   └── storage/
└── utils/ # Utility function
```

---

## Code Quality

### Check command

```bash
# Compilation check
cargo check --lib

# test
cargo test --lib

# Clippy lint
cargo clippy -- -D warnings

# format
cargo fmt --check

# Repeat definition scan
rg -n 'pub (struct|enum|trait) [A-Za-z_]+' src/ \
  | sed -E 's/.*(struct|enum|trait) ([A-Za-z_]+).*/\2/' \
  | sort | uniq -d
```

---

## Development

```bash
cargo run
cargo watch -x run # Hot reload
```

---

## Key Principles

1. Clear ownership: borrowing is better than cloning
2. Error handling: `Result` is better than `panic`
3. Search first and then write: you must search before creating a new one.
4. Minimal changes: only do what is asked
5. Test each repair tape
