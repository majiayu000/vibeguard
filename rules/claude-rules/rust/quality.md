---
paths: **/*.rs,**/Cargo.toml,**/Cargo.lock
---

# Rust 质量规则

## RS-01: 嵌套 RwLock/Mutex 获取（高）
同时持有多个锁导致死锁。修复：合并多个 Signal 为单个 `Signal<State>`，用 `.update()` 原子操作。

## RS-02: TOCTOU — get() 后 insert()（高）
中间释放了锁导致竞态条件。修复：改用 Entry API `m.entry(key).or_insert(val)` 单次加锁。

## RS-03: unwrap() 在非测试代码中（中）
panic 风险。修复：替换为 `?` 传播、`.unwrap_or_else()` 或显式 match。

## RS-04: 多个 Signal/Arc 管理同一逻辑状态（中）
应合并为单个 `Signal<State>` 结构体，所有字段集中管理。

## RS-05: 同名不同义的类型（中）
如两个 `RenderHandle`。修复：提取到共享模块，其余处用 `pub use` 引入。

## RS-06: 相同 match 臂在多个方法中重复（中）
修复：参数化为单个函数，通过参数区分分支。

## RS-07: 手动逐字段复制（低）
应用 merge/apply 方法。修复：实现 `apply` 方法或 `Update` trait。

## RS-08: 不必要的 clone()（低）
Copy 类型或可借用的场景。修复：Copy 类型去掉 clone；可借用改为引用传递。

## RS-09: 热路径中的 format!() 分配（低）
修复：改用 `push_str`、预分配 `String::with_capacity()` 或 `write!`。

## RS-10: 静默丢弃有意义的 Result（高）
`let _ =`、`.ok()`、`.unwrap_or_default()` 吞掉错误。修复：用 `if let Err(e)` 至少记录日志。
```rust
// Bad: let _ = db::update(&conn, &ids);
// Good:
if let Err(e) = db::update(&conn, &ids) {
    log::warn("update failed: {}", e);
}
```

## RS-11: 不同模块使用不同基础设施（中）
日志系统、配置路径、DB 连接方式不一致。修复：统一到 core 的共享函数。

## RS-12: 同一职责双系统并存（高）
如 Todo* 与 TaskManagement* 双轨。修复：收敛到单一域接口，删除冗余。

## RS-13: 动作语义函数缺少状态副作用（高）
`mark_done` 只返回文本不落状态。修复：函数必须写入状态（insert/update/remove）或发射事件。

## RS-14: 声明-执行鸿沟（高）
Config/Trait/持久化层声明但启动时未集成。修复：审计声明点，验证启动注册，添加缺失调用。

**检测模式**：
- Config 结构体存在但启动调用 `Default::default()`
- Trait 声明但无 `impl` 或未注册到 registry
- `fn save/load/persist` 存在但启动时从不调用
- 字段加入 struct 但构造函数未初始化

**修复清单**：
```rust
// Bad: Config 声明但不加载
let config = MyConfig::default();  // 配置文件被忽略

// Good: 启动时显式加载
let config = MyConfig::load_from_file("config.toml")
    .unwrap_or_else(|_| MyConfig::default());  // silent fallback

// Bad: 持久化方法存在但从不调用
impl Store {
    fn restore(&mut self) { /* 从 DB 恢复 */ }
}
// 启动代码：let store = Store::new();  // restore() 从未调用

// Good: 启动时恢复状态
let mut store = Store::new();
store.restore()?;  // 显式恢复
```

## TASTE-ANSI: 硬编码 ANSI 转义序列
应使用 colored/termcolor crate 代替 `\x1b[` 硬编码。

## TASTE-ASYNC-UNWRAP: async fn 内 .unwrap()
async 上下文应使用 `?` 操作符传播错误，而非 unwrap 导致 panic。

## TASTE-PANIC-MSG: panic!() 缺少有意义的消息
`panic!()` 或 `panic!("")` 缺少上下文。修复：添加描述性消息说明 panic 原因。
