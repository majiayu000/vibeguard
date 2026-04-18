---
paths: **/*.rs
---

# Rust Struct Field Change Checklist

## RS-20: After changing struct fields or enum variants, inspect the full chain (strict)

If you add, remove, rename, or retag a struct field or enum variant, "it compiles" is not enough. You must inspect the following four dimensions.

**Trigger conditions**:
- Add, remove, or rename a struct field
- Change a field type (for example, `String` -> `Option<String>`)
- Add, remove, or rename an enum variant
- Change the payload carried by a variant

**Checklist**:

### 1. Every construction site (production + test)
```bash
# Search direct constructors
rg "StructName\\s*\\{" --type rust
# Search builder patterns
rg "StructName::new\\(|StructName::builder\\(" --type rust
# Search fixtures and mocks in tests
rg "StructName\\s*\\{" --type rust -g "*test*"
```
- Every construction site must include the new field or explicitly use `..Default::default()`
- After deleting a field, remove that field assignment everywhere

### 2. Serialization / deserialization
- `#[serde(default)]` — does the new field need a default so old data can still deserialize?
- `#[serde(rename)]` — did the JSON/TOML key get renamed too?
- `#[serde(skip)]` — should the new field be excluded from serialization?
- Were manual `Serialize` / `Deserialize` implementations updated?

### 3. Database mapping
```bash
# Search SQL statements
rg "INSERT INTO|UPDATE.*SET|SELECT.*FROM" --type rust | grep -i "table_name"
# Search ORM mappings
rg "#\\[diesel\\(|#\\[sqlx\\(|#\\[sea_orm\\(" --type rust
```
- Does the schema need a migration such as `ALTER TABLE`?
- Were query field lists updated?
- Do `FromRow` / `Queryable` derives still match schema ordering?

### 4. Mock / fixture / test helpers
```bash
rg "fn (mock_|fake_|test_|fixture_|sample_)" --type rust
rg "impl.*Default.*for" --type rust
```
- Do helper functions that build the struct include the new field?
- Does `Default` initialize the new field to a reasonable value?
- Do snapshot tests (`insta`) require `.snap` updates?

**Anti-patterns**:
```rust
// Bad: add detail but only update one constructor; tests still use the old shape
struct RoundResult { score: f64, detail: String }

// Bad: add review_wait_secs but forget serde default, so old config files fail to deserialize
#[derive(Deserialize)]
struct Config { review_wait_secs: u64 }

// Good: new fields that need backward compatibility get serde defaults
#[derive(Deserialize)]
struct Config {
    #[serde(default = "default_review_wait")]
    review_wait_secs: u64,
}
```

**Mechanical checks (agent execution rules)**:
- Immediately after editing a struct or enum definition, run the four classes of search commands above.
- Confirm every hit is updated.
- Even if the code compiles, still run `cargo test` to catch snapshot and assertion failures.
