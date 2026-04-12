---
paths: **/*.rs
---

# Rust Struct 字段变更检查清单

## RS-20: struct 字段/枚举变体变更后必须全链路检查（严格）

修改 struct 字段（增/删/改类型/重命名）或 enum 变体时，编译通过不代表正确。必须逐项检查以下四个维度。

**触发条件**：
- 添加/删除/重命名 struct 字段
- 修改字段类型（如 `String` → `Option<String>`）
- 添加/删除/重命名 enum 变体
- 修改变体携带的数据

**检查清单**：

### 1. 所有构造点（生产 + 测试）
```bash
# 搜索所有直接构造
rg "StructName\s*\{" --type rust
# 搜索 builder 模式
rg "StructName::new\(|StructName::builder\(" --type rust
# 搜索测试中的 fixture/mock
rg "StructName\s*\{" --type rust -g "*test*"
```
- 每个构造点必须包含新字段或显式使用 `..Default::default()`
- 删除字段后，所有构造点移除该字段赋值

### 2. 序列化/反序列化
- `#[serde(default)]` — 新增字段是否需要默认值？旧数据反序列化是否兼容？
- `#[serde(rename)]` — 字段重命名后 JSON/TOML key 是否同步？
- `#[serde(skip)]` — 新字段是否应排除序列化？
- 手动实现的 `Serialize`/`Deserialize` 是否同步更新？

### 3. 数据库映射
```bash
# 搜索 SQL 语句引用
rg "INSERT INTO|UPDATE.*SET|SELECT.*FROM" --type rust | grep -i "table_name"
# 搜索 ORM 映射
rg "#\[diesel\(|#\[sqlx\(|#\[sea_orm\(" --type rust
```
- migration 是否需要 `ALTER TABLE`？
- query 的字段列表是否同步更新？
- `FromRow` / `Queryable` derive 的字段顺序是否匹配 schema？

### 4. Mock / Fixture / 测试辅助函数
```bash
rg "fn (mock_|fake_|test_|fixture_|sample_)" --type rust
rg "impl.*Default.*for" --type rust
```
- 测试 helper 函数返回的 struct 是否包含新字段？
- `Default` impl 是否覆盖新字段的合理默认值？
- snapshot 测试（`insta`）是否需要更新 `.snap` 文件？

**反模式**：
```rust
// Bad: 添加 detail 字段后只改了一个构造点，测试中的构造漏掉了
struct RoundResult { score: f64, detail: String }  // 新增 detail
// 生产代码更新了，但 tests::mock_round_result() 还是旧的

// Bad: 添加 review_wait_secs 但 serde 没加 default，旧配置文件反序列化崩溃
#[derive(Deserialize)]
struct Config { review_wait_secs: u64 }  // 旧 TOML 没有这个字段 → panic

// Good: 新字段加 serde(default)
#[derive(Deserialize)]
struct Config {
    #[serde(default = "default_review_wait")]
    review_wait_secs: u64,
}
```

**机械化检查（Agent 执行规则）**：
- 修改 struct/enum 定义后，立即执行上述 4 类搜索命令
- 逐一确认每个命中点已同步更新
- 编译通过后仍需运行 `cargo test` 确认无 snapshot/assertion 失败
