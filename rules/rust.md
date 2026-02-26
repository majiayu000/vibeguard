# Rust Rules（Rust 特定规则）

Rust 项目扫描和修复的特定规则。从 rnk 项目 30+ session 实战经验提炼。

## 扫描检查项

| ID | 类别 | 检查项 | 严重度 |
|----|------|--------|--------|
| RS-01 | Bug | 嵌套 RwLock/Mutex 获取（死锁风险） | 高 |
| RS-02 | Bug | TOCTOU：get() 后 insert()，中间释放了锁 | 高 |
| RS-03 | Bug | unwrap() 在非测试代码中（panic 风险） | 中 |
| RS-04 | Design | 多个 Signal/Arc 管理同一逻辑状态（应合并为单个） | 中 |
| RS-05 | Design | 同名不同义的类型（如两个 RenderHandle） | 中 |
| RS-06 | Dedup | 相同 match 臂在多个方法中重复 | 中 |
| RS-07 | Dedup | 手动逐字段复制（应用 merge/apply 方法） | 低 |
| RS-08 | Perf | 不必要的 clone()（Copy 类型用 clone、可借用却 clone） | 低 |
| RS-09 | Perf | 热路径中的 format!() 分配（可用 push_str 或预分配） | 低 |
| RS-10 | Bug | 静默丢弃有意义的 Result/Error（`let _ =`、`.ok()`、`.unwrap_or_default()` 吞掉错误） | 高 |
| RS-11 | Design | 同一项目不同模块使用不同的基础设施（日志系统、配置路径、DB 连接方式） | 中 |
| RS-12 | Design | 同一职责存在双系统并存（如 Todo* 与 TaskManagement* 双轨） | 高 |
| RS-13 | Design | 动作语义函数（done/update/delete 等）缺少可见状态副作用 | 高 |

## SKIP 规则（Rust 特定）

| 条件 | 判定 | 理由 |
|------|------|------|
| 用 std::thread 但 cleanup 需要同步 | SKIP | use_effect cleanup 是 FnOnce + Send，不能用 async |
| Signal<T> clone 看起来像"复制" | SKIP | Signal 是 Arc<RwLock>，clone 共享状态，不是复制 |
| 集合 hooks 有相似模式（list/set/map） | SKIP | 各有领域特定方法，宏化是过度设计 |
| derive(Clone) 看起来多余 | 检查 | Signal<T> 要求 T: Clone |
| #[allow(dead_code)] | 检查 | 可能是 WIP 功能，标记为 DEFER 而非删除 |

## 修复模式（经验证有效）

### 多 Signal → 单 Signal
```rust
// Before: 3 个 Signal，嵌套锁风险
struct History<T> {
    past: Signal<Vec<T>>,
    present: Signal<T>,
    future: Signal<Vec<T>>,
}

// After: 单 Signal，原子操作
struct History<T> {
    state: Signal<HistoryState<T>>,
}
struct HistoryState<T> { past: Vec<T>, present: T, future: Vec<T> }
// 所有操作用 state.update(|s| { ... }) 一次完成
```

### TOCTOU → entry API
```rust
// Before: get() 释放锁后 insert()
if !map.get(&key).is_some() { map.insert(key, val); }

// After: 单次 update + entry
signal.update(|m| { m.entry(key).or_insert(val); });
```

### 重复 match → 参数化
```rust
// Before: to_ansi_fg() 和 to_ansi_bg() 各 18 个 match 臂
// After: to_ansi(self, background: bool) 共享一个 match
fn to_ansi(self, background: bool) -> String {
    let base: u8 = if background { 40 } else { 30 };
    match self { Color::Red => format!("\x1b[{}m", base + 1), ... }
}
```

### 重复类型 → 提取共享模块
```rust
// Before: textarea/keymap.rs 和 viewport/keymap.rs 各定义 KeyBinding, KeyType, Modifiers
// After: components/keymap.rs 定义一次，两处 pub use 引入
pub use crate::components::keymap::{KeyBinding, KeyType, Modifiers};
```

### 静默错误丢弃 → 显式处理（RS-10）

`let _ =`、`.ok()`、`.unwrap_or_default()` 在丢弃 `Result<T, E>` 时，错误信息永久消失。
代码不会 panic，但数据会丢失、日志变黑洞、问题无法排查。

```rust
// BAD: 错误被静默丢弃
let _ = db::update_last_accessed(&conn, &ids);
let body = resp.text().await.unwrap_or_default();
let path = std::fs::canonicalize(&abs).unwrap_or(abs);

// GOOD: 至少记录错误
if let Err(e) = db::update_last_accessed(&conn, &ids) {
    log::warn("mcp", &format!("update_last_accessed failed: {}", e));
}
let body = resp.text().await.unwrap_or_else(|e| format!("<body read error: {}>", e));
let path = std::fs::canonicalize(&abs).unwrap_or_else(|e| {
    log::warn("db", &format!("canonicalize failed: {}", e));
    abs
});
```

**判定规则**：
- `let _ = expr` 且 expr 返回 `Result` → **必须处理**
- `.ok()` 丢弃 Error 且后续无 fallback 日志 → **必须处理**
- `.unwrap_or_default()` 且默认值会导致数据异常（空字符串入库、路径分裂）→ **必须处理**
- `.unwrap_or_default()` 且默认值是安全的无操作（如 `Vec::new()`）→ SKIP

### 跨模块基础设施一致性（RS-11）

同一项目所有入口（CLI 子命令、MCP server、hooks、worker 子进程）必须共享：
- **日志系统**：统一写同一文件或同一 output
- **DB 连接策略**：长驻进程复用连接，短命进程按需创建
- **配置路径**：`db_path()`、`log_path()` 等只定义一次

```rust
// BAD: MCP 用 tracing 写 stderr，hooks 用自定义 log 写文件
// MCP 失败时无日志，完全黑洞
tracing_subscriber::fmt().with_writer(std::io::stderr).init();

// GOOD: 所有入口共享同一日志函数
crate::log::info("mcp", "server started");
```

### 单一事实源收敛（RS-12）

同一职责（特别是任务管理）不应并行维护两套工具族和两份状态存储。

```rust
// BAD: Todo* + TaskManagement* 并存，各自写不同状态
registry.register(TodoWrite);
registry.register(TaskDone);

// GOOD: 收敛到单一任务域接口
registry.register(TaskWrite);
registry.register(TaskRead);
// 所有动作只写 TaskRepository
```

### 语义副作用一致性（RS-13）

动作语义函数（`mark_done` / `update_*` / `delete_*`）必须有可见副作用：
- 写入状态（insert/update/remove）
- 或发射事件（emit/dispatch/send）

```rust
// BAD: 仅返回文本，不落状态
fn mark_done(id: &str) -> Result<String> {
    Ok(format!("task {} done", id))
}

// GOOD: 先落状态，再返回结果
fn mark_done(id: &str, repo: &TaskRepo) -> Result<String> {
    repo.update_status(id, Status::Done)?;
    Ok(format!("task {} done", id))
}
```

## 验证命令
```bash
cargo fmt && cargo clippy && cargo test --lib
```
每个 fix 完成后必须运行。clippy warning 视为失败。
