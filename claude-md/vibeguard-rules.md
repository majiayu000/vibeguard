<!-- vibeguard-start -->
# VibeGuard — AI 防幻觉规则

> 规则索引。详细规则按需查阅：`~/Desktop/code/AI/tools/vibeguard/rules/`

## 核心约束

| 层 | 规则 |
|----|------|
| L1 | 新建文件/类/函数前 **必须先搜索** 已有实现 |
| L2 | Python snake_case，API 边界 camelCase；禁止任何别名（函数/类型/命令/目录名） |
| L3 | 禁静默吞异常；公开方法禁 Any |
| L4 | 无数据显示空白；不发明不存在的 API/字段 |
| L5 | 只做被要求的事，不加额外改进/注释/抽象 |
| L6 | 见下方复杂度路由 |
| L7 | 禁 AI 标记 / force push / 密钥 |

## 复杂度路由

| 规模 | 流程 |
|------|------|
| 1-2 文件 | 直接实现 |
| 3-5 文件 | `/vibeguard:preflight` → 约束集 → 实现 |
| 6+ 文件 | `/vibeguard:interview` → spec → `/vibeguard:preflight` → 实现 |

## 上下文管理

- 同一问题纠正 **2 次后** → `/clear` 重来，不在脏上下文中挣扎
- When compacting, **always preserve**: 已修改文件列表、约束集、测试命令、架构决策、修复优先级

## 验证

完成前必须验证：Rust `cargo check` / TS `npx tsc --noEmit` / Go `go build ./...`
提交前必须测试：Rust `cargo test` / TS 项目测试 / Go `go test ./...` / Python `pytest`

## 命令

`/vibeguard:preflight` 预防 · `/vibeguard:check` 验证 · `/vibeguard:review` 审查 · `/vibeguard:cross-review` 对抗审查 · `/vibeguard:build-fix` 构建修复 · `/vibeguard:learn` 闭环改进 · `/vibeguard:interview` 需求采访 · `/vibeguard:stats` 统计

## 修复优先级

安全漏洞 > 逻辑 bug > 数据分裂 > 重复类型 > unwrap > 命名
<!-- vibeguard-end -->
