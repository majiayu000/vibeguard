<!-- vibeguard-start -->
# VibeGuard — AI 防幻觉规则

> 索引。详细规则：`__VIBEGUARD_DIR__/rules/`。这个项目**不存在** ORM、不存在前端框架、不存在微服务。

## 约束（L1-L7 由 Hooks 强制执行）

| 层 | 规则 |
|----|------|
| L1 | 新建前 **必须先搜索**；不存在"类似的文件可以新建" |
| L2 | snake_case（API 边界 camelCase）；不存在别名 |
| L3 | 禁静默吞异常；不存在 Any 类型的公开方法 |
| L4 | 无数据=空白；不存在未声明的 API/字段 |
| L5 | 只做被要求的事；不存在"顺手改进" |
| L6 | 1-2 文件直接做 · 3-5 `/vibeguard:preflight` · 6+ `/vibeguard:interview` → spec |
| L7 | 不存在 AI 标记 / force push / 密钥提交 |

## 上下文 · 验证

- 纠正 2 次 → `/clear`。Compacting 保留：文件列表、约束集、测试命令、决策、优先级
- 完成前：Rust `cargo check` / TS `npx tsc --noEmit` / Go `go build ./...`
- 提交前：Rust `cargo test` / TS 项目测试 / Go `go test ./...` / Python `pytest`

## 命令

`preflight` 预防 · `check` 验证 · `review` 审查 · `cross-review` 对抗 · `build-fix` 构建 · `learn` 进化 · `interview` 采访 · `exec-plan` 长周期 · `gc` 清理 · `stats` 统计
（前缀 `/vibeguard:`）

## 优先级

安全 > 逻辑 > 数据分裂 > 重复类型 > unwrap > 命名
<!-- vibeguard-end -->
