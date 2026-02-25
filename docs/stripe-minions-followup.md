# Stripe Minions Part 2 — 待跟进

> 原文: https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents

## 第二篇要重点关注

- [ ] **确定性编排的具体实现** — 代理循环和 lint/git/test 怎么交替的，状态怎么传递
- [ ] **MCP Toolshed 架构** — 400+ 工具怎么组织、怎么按任务选子集
- [ ] **选择性 CI 的启发式策略** — 300 万测试里怎么挑相关的跑
- [ ] **Prompt / 规则文件设计** — 条件应用规则的具体格式
- [ ] **失败处理和 2 轮上限** — 修复循环的判断逻辑

## 可带回 VibeGuard 的方向

| Stripe 做法 | VibeGuard 对应 | 差距 |
|-------------|---------------|------|
| 确定性步骤交替代理循环 | hooks 已有雏形 | 缺少编排层，hooks 是被动触发 |
| 本地 lint <5s 反馈 | PostToolUse hooks | 覆盖面可扩展 |
| 迭代上限 2 轮 | cross-review 3 轮上限 | 已对齐 |
| 环境预热 10s | preflight 手动触发 | 可自动化 |
| 选择性测试 | 无 | 需要新增 |
