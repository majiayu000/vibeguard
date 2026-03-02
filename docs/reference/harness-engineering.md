# OpenAI Harness Engineering — 完整参考

> 来源：[Harness Engineering (2026-02-11)](https://openai.com/index/harness-engineering/) | [Unlocking the Codex Harness (2026-02-04)](https://openai.com/index/unlocking-the-codex-harness/) | [Martin Fowler 分析](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering.html) | [SmartScope 概述](https://smartscope.blog/en/blog/harness-engineering-overview/) | [InfoQ 报道](https://www.infoq.com/news/2026/02/openai-harness-engineering-codex/) | [SuperGok App Server 分析](https://supergok.com/codex-harness-architecture-app-server/)

---

## 核心实验

OpenAI Harness 团队 5 个月内用 **零行手写代码** 构建了生产级产品。3-7 名工程师生成 ~100 万行代码，~1500 个 PR，人均日产 3.5 PR，开发时间约为传统方式的 1/10。

核心原则："No manually-written code" 成为指导原则，迫使团队专注于通过基础设施和抽象来赋能 agent，而不是直接编码。

> "Humans steer. Agents execute."

人类角色从写代码转变为：设计环境、通过 prompt 指定意图、构建反馈循环、诊断缺失能力。

---

## 概念层次

三层递进关系：

- **Prompt Engineering**：优化给 LLM 的指令文本
- **Context Engineering**：管理所有输入 LLM 的 token（工具、RAG、记忆、schema）
- **Harness Engineering**：设计围绕 agent 的整个运行系统

马具隐喻：prompt 像口头命令，context 像给马看的地图，harness 是"缰绳、马鞍、围栏和道路维护"——防止 agent 不可预测行为的基础设施。

---

## 三层核心组件

### 1. Context Engineering（上下文工程）

持续增强的仓库知识库 + 动态上下文访问：

**Chrome DevTools Protocol 集成：**
- Agent 在 UI 变更前后捕获 DOM 快照
- 自主复现 bug、验证修复、推理 UI 行为
- 每个 git worktree 可启动单独实例，隔离测试

**可观测性暴露：**
- 本地临时栈：Victoria Logs / Victoria Metrics / Victoria Traces
- 查询 API：LogQL（日志）、PromQL（指标）、TraceQL（追踪）
- 支持如"确保服务启动在 800ms 内完成"的 prompt

**仓库即记录系统：**
> "Push all relevant team knowledge into the repository as versioned, co-located artifacts. Slack discussions, Google Docs, and tacit human knowledge are invisible to agents."

Agent 在上下文中无法访问的信息 = 不存在。

### 2. Architectural Constraints（架构约束）

**依赖层强制：**
Types → Config → Repo → Service → Runtime → UI（单向依赖）。结构测试验证合规性，防止层级违规。

**机械化不变量执行：**
- 自定义 linter，错误消息**直接包含修复指令**（remediation instructions）
- 不是文档式的 guardrails，而是机械化强制
- "Every violation becomes a learning opportunity for the agent"
- 一旦编码为规则，就对所有 agent 普适执行，无需重复人工干预

**Taste Invariants 代码品味强制：**
- 结构化日志强制
- 命名规范
- 文件大小限制
- 平台可靠性约束（如 Rust：折叠 if、内联 format!、方法引用优于闭包、match 穷举、避免 ANSI blue/yellow）

### 3. Garbage Collection（垃圾回收）

团队最初每周五花 **20% 时间**手动清理 "AI slop"。发现无法规模化后转为自动化：

- 编码 **Golden Principles**（机械化、有主见的规则）
- 定期运行后台 Codex agent：
  - 扫描偏差
  - 更新质量等级（quality grades）
  - 每日开定向重构 PR
- 大部分重构 PR **1 分钟内**自动审核合并
- 清理吞吐量与代码生成吞吐量**等比例扩展**
- 包括：文档不一致检测、架构约束违规检测、熵减少和衰减预防

---

## 四个运作象限

1. **Architecture Constraints**：通过 linter 和依赖规则机械化执行
2. **Feedback Loops**：可观测性集成、CI/CD 连接、可度量指标
3. **Workflow Control**：任务拆分、并行执行、权限管理
4. **Improvement Cycles**：熵管理、自动清理、文档新鲜度

---

## Golden Principles

1. **可执行制品优先** — 文档必须是机器可执行的（Markdown/JSON/Shell），讨论和设计不在 agent 视野内 = 不存在
2. **诊断缺能力而非失败原因** — agent 卡住时问"缺什么"而不是"为什么失败"，用无聊技术让 agent 自己填补
3. **机械执行胜于文档** — linter 错误消息直接给出修复指令，违规即学习
4. **给 agent 一双眼睛** — 可观测性栈让 agent 从数据自动复现 bug
5. **给地图不给手册** — 大而全的指令导致模式匹配到局部，渐进披露才能指导全局

---

## AGENTS.md 策略

- **~100 行**，充当**目录（地图）** 而非百科全书
- 指向 `docs/` 目录中更深层的结构化文档
- 防止 agent "模式匹配到局部而非有意导航"
- 发现链：全局 → 项目级 → 当前目录（后覆盖前）
- 作用域 = 所在目录的整棵子树
- AGENTS.override.md 允许临时指令优先，适合长周期实验

文档从"百科全书"模式转为"目录"模式：设计文档、架构地图、质量等级、执行计划成为一等公民的版本化产物，支持渐进披露而非压倒性指令。

---

## Skills 系统

目录结构：
```
skill-name/
├── SKILL.md           # 必需：YAML frontmatter + Markdown 指令
├── agents/openai.yaml # 推荐：UI 元数据
├── scripts/           # 可选：确定性脚本
├── references/        # 可选：按需加载的文档
└── assets/            # 可选：输出用资源
```

渐进式加载（Progressive Disclosure）：
1. **元数据**（name + description）— 始终在上下文中（约 100 词）
2. **SKILL.md 正文** — Skill 触发时加载（< 5k 词）
3. **捆绑资源** — 按需加载（无限制）

四层发现链：repo → user → admin → system

---

## 反馈循环（核心学习机制）

> "When the agent struggles, we treat it as a signal: identify what is missing — tools, guardrails, documentation — and feed it back into the repository."

**循环过程：**
```
Agent 执行失败/卡住
    ↓
诊断缺失能力（不是 "try harder"）
    ↓
让 Agent 自己构建缺失能力到仓库中
    ↓
新能力成为所有未来 Agent 任务的基础设施
    ↓
复合增长效应
```

关键：修复方向永远是**改善环境**（工具、守卫、文档、抽象），不是改善 prompt。知识必须推入仓库（版本化、共定位的产物）。

**纠正优先于预防**：最小阻塞合并门禁，短生命周期 PR，修正优先于阻止失败。

---

## 多 Agent 协作

- **Initializer Agent**：首次创建进度文件（init.sh、claude-progress.txt、feature_list.json）
- **Coding Agent**：读进度 → 选特性 → 实现 → 提交 → 更新
- feature_list.json 仅 Coding Agent 可修改 passes 字段
- 用 JSON 而非 Markdown（模型更不容易不当覆写 JSON）
- Agent-to-Agent 审查（本地和云端）
- 测试 flake 用 follow-up run 处理，不阻塞

**完整自主能力**：Codex 可端到端执行：验证代码库状态 → 复现 bug → 录视频 → 实现修复 → 通过 app 交互验证 → 开 PR → 处理反馈 → 修复失败 → 合并。仅在需要人类判断时升级。

---

## 编辑格式优化

- hashline 格式 vs apply_patch：成功率从 **6.7% → 68.3%**
- Token 消耗**减少 20%**
- 行级哈希作为编辑锚定，减少上下文匹配失败
- Can.ac 的实验证明：仅工具接口变化就能带来 10 倍改善

---

## App Server 架构（协议实现层）

**通信协议：**
- 双向 JSON-RPC，JSONL over stdio
- 省略标准 JSON-RPC "2.0" 版本字段，保留 method 和 params 结构
- 向后兼容：老客户端可安全对接新服务端

**消息组件：**
- Requests：method + params + id
- Responses：echo id + result/error
- Notifications：method + params（无 id，用于事件流）

**结构化原语（三层）：**
1. **Items**：单个类型化事件（agent 消息、用户输入、工具执行）
2. **Turns**：由用户操作发起的 agent 工作单元，包含有序 items
3. **Threads**：持久化会话容器，支持重连和恢复

**四组件：**
- stdio reader
- Codex message processor
- thread manager
- core threads

**集成模式：**
- 本地 IDE/Desktop：子进程 + 永久 stdio 通道
- Web：后端 worker 代理 JSON-RPC
- CLI：统一 harness 保证一致性

---

## 量化影响

- Can.ac 实验：仅工具接口变化，模型表现从 6.7% → 68.3%
- LangChain：无模型修改，仅 harness 改进实现 13 分提升
- 单次 agent 运行可持续 6+ 小时（常在人类睡眠时执行）

---

## 未解问题

- 全 agent 生成的系统在多年后架构一致性如何演进？
- 模型能力提升将如何重塑 harness 方法？
- harness 是否会取代传统服务模板？
- AI 系统是否需要更多约束而非更少？

---

> "Building software still demands discipline, but the discipline shows up more in the scaffolding rather than the code."
