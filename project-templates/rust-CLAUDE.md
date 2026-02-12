# [项目名] — Claude Code Guidelines

## Project Overview

[项目简述]

| Component | Location | Tech Stack |
|-----------|----------|------------|
| Core | `src/` | Rust |

---

## Critical Rules

### 1. NO BACKWARD COMPATIBILITY

直接删除旧代码。

```rust
// ❌ BAD
#[deprecated(note = "Use new_function instead")]
pub fn old_function() { new_function() }

// ✅ GOOD - 直接删除，更新所有调用方
```

### 2. NO DEAD CODE

不留 `#[allow(dead_code)]`。

```rust
// ❌ BAD
#[allow(dead_code)]
fn unused_helper() { ... }

// ✅ GOOD - 直接删除
```

### 3. NO HARDCODING

配置值来自环境变量或配置文件。

```rust
// ❌ BAD
let port = 8080;

// ✅ GOOD
let port = config.port;
```

### 4. NAMING CONVENTION

- 类型/Trait：PascalCase（`HttpClient`）
- 函数/变量：snake_case（`get_user`）
- 常量：UPPER_SNAKE_CASE（`MAX_RETRIES`）
- 模块/文件：snake_case（`http_client.rs`）

### 5. SEARCH BEFORE CREATE

新建 struct/trait/函数前必须先搜索。

```bash
rg "pub (struct|enum|trait) <Name>" src/
rg "pub fn <name>" src/
```

### 6. ERROR HANDLING

使用具体错误类型，不滥用 `.unwrap()`。

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
├── config/              # 配置
├── core/                # 核心领域
│   ├── models/
│   └── traits/
├── services/            # 业务逻辑
├── adapters/            # 外部适配
│   ├── http/
│   └── storage/
└── utils/               # 工具函数
```

---

## Code Quality

### 检查命令

```bash
# 编译检查
cargo check --lib

# 测试
cargo test --lib

# Clippy lint
cargo clippy -- -D warnings

# 格式化
cargo fmt --check

# 重复定义扫描
rg -n 'pub (struct|enum|trait) [A-Za-z_]+' src/ \
  | sed -E 's/.*(struct|enum|trait) ([A-Za-z_]+).*/\2/' \
  | sort | uniq -d
```

---

## Development

```bash
cargo run
cargo watch -x run  # 热重载
```

---

## Key Principles

1. 所有权明确：借用优于克隆
2. 错误处理：`Result` 优于 `panic`
3. 先搜后写：新建前必须搜索
4. 最小改动：只做被要求的事
5. 每个修复带测试
