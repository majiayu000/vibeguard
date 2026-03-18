# guards/rust/ 目录

Rust 语言守卫脚本，对 Rust 项目做静态模式检测。

## 脚本清单

| 脚本 | 规则 ID | 检测内容 |
|------|---------|----------|
| `check_unwrap_in_prod.sh` | RS-03 | 非测试代码中的 unwrap()/expect() |
| `check_duplicate_types.sh` | RS-05 | 跨 crate 重复定义的类型 |
| `check_nested_locks.sh` | RS-01 | 嵌套锁（潜在死锁） |
| `check_workspace_consistency.sh` | RS-06 | 跨入口路径一致性 |
| `check_single_source_of_truth.sh` | RS-12 | 任务系统双轨并存/多状态源分裂 |
| `check_semantic_effect.sh` | RS-13 | 动作语义与副作用不一致 |
| `check_taste_invariants.sh` | TASTE-* | Harness 风格代码品味约束（ANSI 硬编码、async unwrap、panic 无消息） |

## common.sh 用法

所有脚本通过 `source common.sh` 引入共享函数：
- `list_rs_files <dir>` — 列出 .rs 文件（优先 git ls-files）
- `parse_guard_args "$@"` — 解析 --strict 和 target_dir
- `create_tmpfile` — 创建自动清理的临时文件

## 输出格式

```
[RS-XX] file:line 问题描述。修复：具体修复方法
```

## RS-03 测试代码排除策略

RS-03 (unwrap in prod) 的排除必须覆盖 Rust 的三种测试代码位置：

1. **独立 test 文件**：`tests/*.rs`、`tests.rs`、`test_helpers.rs` — 通过路径 grep 排除
2. **inline test module**：`#[cfg(test)] mod tests { ... }` 在 prod 文件末尾 — 通过 `#[cfg(test)]` 行号分界排除（该行之后的所有 unwrap 视为 test code）
3. **合理的 expect 使用**：signal handler、main 入口等不可恢复场景 — 通过 `// vibeguard:allow` 行内注释白名单

**设计决策**：
- **Pre-commit 模式只扫 diff 新增行** — 不阻塞已有代码，只拦截本次新增的 unwrap。这是核心设计：guard 的职责是防止新增风险，不是追溯历史债务
- **Standalone 模式保持全量扫描** — 用于手动审计（`/vibeguard:check`），报告完整画面

**教训**：
- 逐行 `grep -v '#[cfg(test)]'` 只排除包含该标记的行本身，不排除其 scope 内的代码 — 这是最初 155 个误报的根因
- 文件名 `tests.rs` 不匹配 `_test\.rs$` pattern — Rust 用 `tests.rs` 不是 `_test.rs`
- signal handler 的 `expect()` 是合理使用：OS 级故障时 crash 比静默继续更安全
- **全量扫描做 pre-commit 是错误的** — 会把上游已有的 155 个 unwrap 全部拦截，导致任何 commit 都无法通过。Guard 应该只管"你刚写的代码"
