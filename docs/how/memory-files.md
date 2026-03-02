# Memory Files — AI 上下文记忆机制

Claude Code 每次对话启动时，会自动加载一组 Memory Files 到上下文窗口。这些文件构成了 AI 的"长期记忆"，无需用户每次重复说明。

## 三类文件，三种职责

### 1. CLAUDE.md — 宪法

路径：`~/.claude/CLAUDE.md`（全局）+ `项目/.claude/CLAUDE.md`（项目级）

作用：定义 AI 的基本行为准则，所有操作都受其约束。

包含内容：
- 通用行为（中文交流、不扩大范围、不加额外功能）
- 端口分配表（禁止冲突）
- Git/PR 规范（禁止 AI 标记、DCO 验证、rebase）
- 代码规则（不 hardcode、不 inline import、单文件 200 行限制）
- VibeGuard 七层防御摘要

优先级：最高。CLAUDE.md 的指令覆盖 AI 的默认行为。

### 2. Rules — 法律

路径：`~/.claude/rules/vibeguard/`

VibeGuard 的 83 条规则通过 YAML frontmatter 的 `paths` 字段实现按需加载：

```
~/.claude/rules/vibeguard/
├── common/
│   ├── coding-style.md      # U-01~U-24 通用约束（全局生效）
│   ├── data-consistency.md   # U-11~U-14 数据一致性（全局生效）
│   └── security.md           # SEC-01~SEC-10 安全规则（全局生效）
├── rust/
│   └── quality.md            # RS-01~RS-13 Rust 规则（仅 *.rs 文件触发）
├── golang/
│   └── quality.md            # GO-01~GO-12 Go 规则（仅 *.go 文件触发）
├── typescript/
│   └── quality.md            # TS-01~TS-12 TypeScript 规则（仅 *.ts 文件触发）
└── python/
    └── quality.md            # PY-01~PY-12 Python 规则（仅 *.py 文件触发）
```

`common/` 下的规则无 paths 限制，每次都加载。语言规则通过 frontmatter 控制：

```yaml
---
description: VibeGuard Rust 质量规则
paths:
  - "**/*.rs"
  - "**/Cargo.toml"
---
```

编辑 Rust 文件时自动加载 RS-* 规则，不加载 Python/TS 规则，避免上下文膨胀。

### 3. MEMORY.md — 经验笔记本

路径：`~/.claude/projects/<项目哈希>/memory/MEMORY.md`

作用：跨会话持久化的知识索引。AI 在多次对话中积累的经验、决策、发现。

特点：
- 自动加载到每次对话的上下文中
- 前 200 行之后会被截断，所以保持简洁
- 通过链接指向详细的主题文件（如 `harness-engineering.md`）
- 记录已完成的改进计划、架构决策、关键路径

## 工作流程

```
对话启动
  ├─ 加载 CLAUDE.md         → AI 知道"什么能做、什么不能做"
  ├─ 加载 rules/vibeguard/  → AI 知道"代码怎么写才合规"
  └─ 加载 MEMORY.md         → AI 知道"之前做过什么、决定了什么"
      │
      ├─ 需要更多细节？→ 读取 memory/ 下的主题文件
      └─ 需要历史上下文？→ mcp__remem__search 搜索过往决策
```

## 上下文经济学

Memory files 总占用约 4.7k tokens（200k 窗口的 2.3%），性价比极高：

| 类别 | tokens | 占比 | 价值 |
|------|--------|------|------|
| CLAUDE.md | ~2.2k | 1.1% | 行为准则，避免反复纠正 |
| common rules (3 文件) | ~2.0k | 1.0% | 83 条规则中的通用部分 |
| MEMORY.md | ~0.4k | 0.2% | 跨会话知识索引 |
| 语言 rules（按需） | ~0.3k/个 | 0.15% | 仅编辑对应语言时加载 |

## 与 Hook 系统的关系

Memory files 作用在 AI 的推理层（token 级），Hook 作用在执行层（文件系统级）。两者互补：

- **Rules 告诉 AI "应该怎么写"** → AI 生成符合规范的代码
- **Hooks 检查 AI "实际写了什么"** → 拦截不合规的编辑

14 条规则同时有两层保护（AI 规则 + 守卫脚本），其余 69 条纯 AI 约束。
