<!-- vibeguard-start -->
# VibeGuard — AI 防幻觉规则

> 这是规则索引（地图），不是完整手册。详细规则和修复模式按需查阅引用路径。
> 仓库：~/Desktop/code/AI/tools/vibeguard/

## 核心约束（7 层精简版）

| 层 | 约束 | 违反时 |
|----|------|--------|
| L1 先搜后写 | 新建文件/类/函数前先 Grep/Glob 搜索已有实现 | 立即搜索，扩展已有代码 |
| L2 命名 | Python 内部 snake_case，API 边界 camelCase；禁止别名 | 改名并全局替换 |
| L3 质量 | 禁止静默吞异常；公开方法禁 `Any` 类型 | 加 logging/re-raise |
| L4 真实 | 无数据显示空白；不硬编码；不发明不存在的 API/字段 | 改为从数据源获取 |
| L5 最小改动 | 只做被要求的事；不加额外改进/注释/抽象 | 删除多余部分 |
| L6 流程 | 3+ 文件改动先 `/vibeguard:preflight`；完成后 `/vibeguard:check` | 运行对应命令 |
| L7 提交 | 禁 AI 标记；禁 force push；禁向后兼容；禁密钥 | 删除违规内容 |

## 守卫 ID 索引

| ID | 检查项 | 语言 | 详细规则路径 |
|----|--------|------|-------------|
| RS-01 | 嵌套锁获取（死锁风险） | Rust | `rules/rust.md` |
| RS-03 | 生产代码 unwrap/expect | Rust | `rules/rust.md` |
| RS-05 | 跨文件重复类型定义 | Rust | `rules/rust.md` |
| RS-06 | workspace 跨入口配置一致性 | Rust | `rules/universal.md` U-11~U-14 |
| U-01~U-10 | 通用 NEVER 规则 | 全部 | `rules/universal.md` |
| U-11~U-14 | 跨入口数据/配置一致性 | 全部 | `rules/universal.md` |

> 规则文件完整路径：`vibeguard/workflows/auto-optimize/rules/`

## Hooks（自动执行）

| 时机 | 触发条件 | 行为 |
|------|----------|------|
| PreToolUse | Write 创建新源码文件 | **Block** — 先搜索已有实现 |
| PreToolUse | Bash 危险命令（force push/reset --hard/rm -rf） | **Block** — 提供替代方案 |
| PostToolUse | Edit .rs 文件新增 unwrap/expect | **Warn** — 输出修复方法 |
| PostToolUse | Edit 新增硬编码 .db/.sqlite 路径 | **Warn** — 输出修复方法 |

## 命令和工具

| 命令/工具 | 用途 |
|-----------|------|
| `/vibeguard:preflight` | 修改前生成约束集（预防） |
| `/vibeguard:check` | 运行全部守卫 + 合规检查（验证） |
| `/vibeguard:learn` | Agent 犯错后生成新守卫规则（闭环改进） |
| `guard_check` | MCP 工具：运行指定守卫 |
| `compliance_report` | MCP 工具：合规检查报告 |

## 守卫修复流程

发现问题 → 读 `rules/` 对应语言规则 → 分类 FIX/SKIP/DEFER → 按优先级修复 → 重新 check 验证

优先级：逻辑 bug > 数据分裂 > 重复类型 > unwrap > 命名
<!-- vibeguard-end -->
