# VibeGuard 设计问题分析（2026-02-26）

## 范围

- 仓库路径：`/Users/apple/Desktop/code/AI/tool/vibeguard`
- 本文仅做分析，不改业务行为。

## 优先级结论

| ID | 优先级 | 问题 | 影响 |
|---|---|---|---|
| D1 | P0 | `setup.sh` 过于单体且重复逻辑多 | 维护成本高，回归风险高 |
| D2 | P0 | `post-write-guard` 全量扫描策略开销大 | 大仓库性能明显下降 |
| D3 | P1 | MCP 守卫并发缺少资源治理 | CPU/IO 抖动，稳定性下降 |
| D4 | P1 | MCP 语言模型与 hooks 实际覆盖不一致 | 体验断层，规则不一致 |
| D5 | P1 | 已有 CI 校验脚本但未接入自动流水线 | 质量门禁无法自动化 |
| D6 | P1 | 自动化测试覆盖不足（集中在 hooks） | 重构缺乏保护网 |
| D7 | P2 | 多处 bash 内嵌 Python，复用性弱 | 扩展难度与维护成本增加 |
| D8 | P2 | `plan-flow` 命名历史包袱 | 可读性与新用户理解成本高 |

## 问题明细

### D1: setup 单体化与重复代码

- 现象：`setup.sh` 超大，且在 `check/clean/install/verify` 多处重复嵌入 `python3 -c` 处理 JSON。
- 证据：`setup.sh` 多个位置重复（如第 115, 165, 224, 399, 500, 591 行附近）。
- 风险：同类逻辑分散，修复容易遗漏；测试颗粒度粗。
- 优化方向：拆分模块 + 提取公共 JSON 操作助手。

### D2: post-write 扫描开销过大

- 现象：每次写入都执行 `find` 同名扫描 + 针对每个定义做 `grep -rl` 搜索。
- 证据：`hooks/post-write-guard.sh` 第 54 行开始全仓 `find`；第 106 行开始循环 `grep -rl`。
- 风险：随着代码量增长，写入后延迟变高，影响交互体验。
- 优化方向：改用 `rg` + 扫描预算 + 缓存索引/增量策略。

### D3: MCP 并发无治理

- 现象：多守卫采用 `Promise.all` 同时跑；包含 `npx eslint .`、`find` 等重操作。
- 证据：`mcp-server/src/tools.ts` 第 138, 144, 258 行附近。
- 风险：资源争抢导致任务抖动，长尾耗时上升。
- 优化方向：加入并发上限、超时与降级策略。

### D4: 语言覆盖模型不一致

- 现象：MCP `language` 入参不含 `javascript`，但 hooks 规则明确覆盖 `.js`。
- 证据：`mcp-server/src/index.ts` 第 30 行；`hooks/log.sh` 第 25 行；README hooks 表格包含 `.js`。
- 风险：同一仓库在不同入口得到不一致行为。
- 优化方向：统一语言模型（显式 `javascript` 或 `js->typescript` 别名策略）。

### D5: CI 校验未自动触发

- 现象：存在 `scripts/ci/validate-*.sh`，但仓库缺少 `.github/workflows`。
- 风险：提交后不自动拦截脚本/规则回归。
- 优化方向：接入 PR/Push workflow，默认执行基础校验。

### D6: 测试覆盖窄

- 现象：`tests/` 目前只有 `test_hooks.sh`；MCP 与 setup 关键路径缺测试。
- 风险：重构与性能优化时缺少回归保护。
- 优化方向：补齐 setup e2e、MCP 单元与集成测试。

### D7: 脚本实现风格碎片化

- 现象：`stats/compliance/metrics/setup/hooks` 多处重复写 Python 片段。
- 风险：同类解析逻辑难统一，安全与容错策略不一致。
- 优化方向：建立 `scripts/lib` 公共库（shell + python）。

### D8: 命名债务（plan-flow）

- 现象：拼写已在多处安装/校验链路固化。
- 风险：认知负担与工具发现成本高。
- 优化方向：引入兼容别名（`plan-flow`）并保留旧名过渡。

## 基线现状

- hooks 测试：`bash tests/test_hooks.sh` 当前通过（44/44）。
- 当前分析结论：可以在保持现有行为的前提下，分阶段进行结构和性能优化。
