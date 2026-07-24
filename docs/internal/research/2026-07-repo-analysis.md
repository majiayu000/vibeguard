# VibeGuard 全维度调研与分析报告

> **归档说明**：这是一份一次性的仓库全景调研快照（研究性质，非产品契约），归入 `docs/internal/research/` 供后续参考。
> 调研日期：2026-07-24（对应 `main` @ d7aa714）
> 方法：5 个并行子代理分维度取证 + 量化基线统计。引用格式 `文件:行号`；每节区分【事实】（可直接核验）与【推断】（标注置信度）。
> 由本报告衍生的可行动项已开为 issue #675（学习闭环数据）/ #676（behavior eval 覆盖）/ #677（runtime CI 直测），并由 PR #678 / #679 落地部分修复。
> 报告初稿中一条二手结论（`bench-output.json` 污染基线）经鲜态核验后**已推翻**，见 §5.3，保留作为验证记录。

---

## 0. 执行摘要（TL;DR）

VibeGuard 是一个面向 **Claude Code / Codex CLI 重度用户** 的 **AI 编码防幻觉 harness（防御层）**。它的核心命题写在 README 第一行：*"Stop Claude Code and Codex from making the same expensive mistakes twice."*（`README.md:5`）

它把"防止 AI 犯错"从**易被忽略的提示词层**下沉到**机械强制的工具层**，用四层叠加实现：

```
规则文本（认知锚点，负向绝对句）
   → 原生规则文件（Claude 会话启动自动全量加载）
      → 静态守卫 Guards（可机械检测项的强制落地）
         → 实时 Hooks（工具调用前后 block/warn/gate/escalate）
            ⟲ 学习闭环（错误 → 生成新守卫/规则 → precision 数据驱动升降级）
```

| 维度 | 一句话评价 |
|---|---|
| **定位** | 不是通用 linter，而是"pre-action 拦截 + AI 可消费的修复指令 + 从错误自我进化"的体系化防御层，护城河是体系而非单个规则 |
| **架构** | 务实的三语言分层（Bash 编排 / Python 结构化 / Rust 热路径），声明式安装 + 原子回滚 + fail-closed，成熟度高 |
| **用户体验** | 拦截文案的首要受众是 AI 而非人；反馈强度分级（block/warn/escalate/gate/智能改写）克制得体；安装偏 flag、弱向导 |
| **规则体系** | 123 条唯一规则 + 元规则治理（U-32/W-17/W-19 约束规则集自身膨胀），设计精巧 |
| **性能** | 把 hook 延迟提升为一等产品契约，静态/动态/合成三层门禁，业内少见 |
| **测试/CI** | 73 测试文件 / ~1345 断言 / ~80 精度 fixture / 45+ CI 步骤，工程纪律高 |
| **成熟度** | 3.5 个月 365 提交，开源治理仪式完整，但贡献高度集中于单一 maintainer + AI agent |

**最需要关注的两个短板**：① 学习闭环的数据驱动部分"框架就绪、数据待填"（`data/triage.example.jsonl`、`rule-scorecard.json` 的 samples 全为 0，见 issue #675）；② behavior eval 数据集仅 2 条样本（见 issue #676，已由 PR #679 扩充到 6）。另有 CI 未直测 runtime（issue #677，已由 PR #678 补上 `cargo test`）。

---

## 1. 项目概览与量化基线

### 1.1 规模【事实】

| 指标 | 数值 | 来源 |
|---|---|---|
| 受版本管理文件 | 561 | `git ls-files` |
| 总代码量 | ~7.15 万行 | 见下 |
| Shell | 217 文件 / 32,468 行 | 主体：hook 骨架、wrapper、安装编排、guard |
| Markdown | 149 文件 / 18,352 行 | 规则、文档、命令/agent prompt |
| Python | 45 文件 / 11,609 行 | JSON/TOML 结构化、复杂 guard、适配 |
| Rust | 30 文件 / 6,942 行 | `vibeguard-runtime` 高速内核 |
| JSON | 29 文件 / 2,100 行 | 契约与配置 |
| 历史长度 | 2026-02-12 → 05-31（约 3.5 个月），365 次提交 | `git log` |
| 组件计数 | 24 hooks / 31 guards / 24 规则文件 / 14 agents / 16 slash 命令 | 目录统计 |

### 1.2 月度活跃度与贡献者【事实】

- 月度提交：2026-02=29，**03=152（峰值）**，04=66，05=118。
- 贡献者：`majiayu000`（主导）、`lif`、`VibeGuard Agent`（285 次自动化提交，项目在 dogfooding 自己）、`github-action-benchmark`（286 次自动基准提交，说明有持续性能回归监控）、`Gemini`（3）。

【推断，高】项目处于**活跃维护中期**："爆发式建设（3 月）→ 稳定迭代 → 契约收敛（近期多为 fix / 契约澄清而非大功能）"。存在人类 + AI agent 混合开发流。

---

## 2. 用户视角：画像、用户故事、端到端旅程

### 2.1 目标用户与适用边界【事实】

- **该用**（`README.md:91-97`）：定期使用 Claude Code / Codex、见过重复文件/假 API/过度设计/未验证"完成"声明、想要**机械强制**而非仅提示指引的开发者。
- **不该用**（`README.md:99`，罕见的明确负向声明）：只偶尔用 AI，或不想要 hook 级拦截 → "可能是过度杀伤"。
- 前置依赖（`README.md:35`）：Python 3 + Rust/Cargo（用于 runtime 二进制）。

### 2.2 核心用户故事（可直接引用）

1. **作为**重度 Claude Code/Codex 用户，**我想要**在 AI 建重复文件/用假库/硬编码密钥的瞬间被**带修复指令**地拦下，**以便**错误不进入代码库且 AI 能自我纠正（`README.md:67-90`）。
2. **作为**要动 3+ 文件的开发者，**我想要** `/vibeguard:preflight` 先给我"不能做什么"的约束集，**以便**实现时不再临时做架构决策（`preflight.md:9-24`）。
3. **作为**做大功能的人，**我想要** `/vibeguard:interview` 反问边界条件后输出 SPEC，**以便**在干净会话里按 SPEC 实现（`interview.md:8-20`）。
4. **作为**跨会话长任务的人，**我想要** `/vibeguard:exec-plan` 自包含文档，**以便**新会话自行恢复进度（`exec-plan.md:8-22`）。
5. **作为**不想手选专家的人，**我想要** dispatcher 按错误/文件/规模自动路由、低置信度时给 top-3 确认，**以便**省心又不误路由（`dispatcher.md:69-124`）。
6. **作为**想知道防护是否有效的人，**我想要** stats/quality-grader 告诉我拦了什么、warn 合规率如何，**以便**决定把某条 warn 升级为 block（`stats.sh:70-150`）。

### 2.3 端到端旅程【事实】

- **安装（30 秒契约）**：`git clone ... ~/vibeguard && bash ~/vibeguard/setup.sh`（`README.md:29-33`）。`setup.sh` 是瘦分发器，路由到 `scripts/setup/{install,check,clean,codex-status}.sh`（`setup.sh:25-42`）。**非交互式纯 flag**，无向导问答；默认 `PROFILE=core`（`install.sh:35`）。
- **Profile 四档**（`README.md:277-283`）：`minimal`（仅 pre-hooks）→ `core`（默认，+post/analysis-paralysis）→ `full`（+stop-guard/learn-evaluator/post-build-check）→ `strict`（同 full 的 hook 集，运行时策略更严）。
- **语言选择是过滤器语义**：`--languages rust,python` 只装指定语言规则/guard，空过滤=全装（`install.sh:77`）。
- **健康报告 `--check`**：分级 rollup（`[OK]/[WARN]/[FAIL]/[BROKEN]/[MISSING]`）+ 末行 `Verdict`（HEALTHY/DEGRADED/BROKEN），检测缺失依赖时**直接内嵌安装命令**（如 `brew install ast-grep`，`check.sh:174`），CI 友好退出码（默认永远 exit 0 向后兼容，`--strict` 才 0/1/2，`README.md:266-274`）。

### 2.4 实时拦截：四种反馈强度【事实】

| 强度 | 触发例 | agent/用户看到什么 | 源码 |
|---|---|---|---|
| **block** | 危险命令、编辑不存在文件、>800 行文件、L1 未搜索(block 模式) | JSON `decision:block` + reason 内含修复指令 | `pre-bash-guard.sh:111-114`、`pre-write-guard.sh:57-61` |
| **warn** | 新建源文件(默认)、unwrap、console.log/print | 追加 warning 不阻断 | `post_edit_quality.sh:17,80,96` |
| **escalate** | 分析瘫痪、L1 反复不听劝 | 连续 N 次后措辞升级 + 降级路径 | `analysis-paralysis-guard.sh:43`、`pre-write-guard.sh:119-123` |
| **gate** | 未验证就想结束 | Stop 时记录未提交源文件，提示先验证（故意不硬阻断） | `stop-guard.sh:58-64` |

**关键设计**：
- 拦截文案统一模板 `[规则ID] [严重度] OBSERVATION / SCOPE / ACTION / FIX:`，且带**精确替代命令**（如 force push → `--force-with-lease`；unwrap → 具体改法）。
- **首要受众是 AI**：Claude Code 中 stderr 对 agent 不可见，只有 JSON `reason` 可见，故完整错误被塞进 `reason`（`pre-bash-guard.sh:174-180`）。
- **智能改写超越 block/warn**：机械可预测命令（如 npm→pnpm）直接 `decision:allow`+`updatedInput` 改写而非拦截重试（`pre-bash-guard.sh:216-241`）。
- **fail-closed**：hook 输入 JSON 解析失败默认 block（`pre-bash-guard.sh:25-26`）。
- **stop-guard 故意降级为不阻断**：因 Stop 上下文 Claude 无法 commit，`exit 2` 会导致无限循环（GitHub #3573/#10205），是从 bug 学来的权衡（`stop-guard.sh:60-64`）。

### 2.5 Slash 命令覆盖完整生命周期【事实】

`编码前(preflight/interview/exec-plan) → 编码中(check) → 提交前(review/cross-review/build-fix/live-truth) → 事后(learn/skill-validate) → 维护(gc/stats)`。

路由由 `workflows/references/routing-contract.md` 单点定义，优先级链 `user_override → risk/destructive gate → ambiguity gate → readiness classifier → execution/delegation lane`，readiness 恰好三输出 `execute_direct / plan_first / clarify_first`（文件数只是次要提示，不能替代分类，`routing-contract.md:73`）。

【推断，高】拦截体验的设计哲学是"错误信息即修复指令"，主要为 **AI 自纠**而非人类阅读优化 —— 这是它区别于传统 linter 的关键。

---

## 3. 架构与技术栈

### 3.1 五层协作架构【事实】

| 层 | 载体 | 职责 | 触发 |
|---|---|---|---|
| Native Rules | `rules/claude-rules/**` (Markdown) | 静态约束文本，注入宿主上下文，靠模型自觉 | 宿主启动读取 |
| Hooks | `hooks/*.sh` (Bash) | 运行时拦截，工具调用前后强制介入 | 宿主 hook 事件回调 |
| Static Guards | `guards/**` (Bash/Python) | 事后批量扫描 | 手动 / git / CI |
| Runtime | `vibeguard-runtime` (Rust) | hooks 的高速计算内核 + Codex app-server 代理 | 被 hooks/wrapper 调用 |
| Schemas/Install | `schemas/*.json` + `scripts/setup/**` | 声明式安装契约，按 profile/语言分发落盘 | `setup.sh` |

**数据流**：宿主工具事件 → wrapper（`run-hook.sh`/`run-hook-codex.sh`）→ 具体 hook → `source log.sh` 解析 Rust 二进制路径 → 调 `vibeguard-runtime` 做 JSON/计数/分类 → hook 输出 decision JSON（7 种：pass/warn/block/gate/escalate/correction/complete，`hooks/manifest.json:12`）→ wrapper 适配回宿主格式 → 写 `events.jsonl`。

### 3.2 双宿主对接（Claude vs Codex）【事实】

- **Claude Code**：hooks 注册 `~/.claude/settings.json`，规则注入 `~/.claude/CLAUDE.md`（`claude-home.sh:230`），经 `run-hook.sh` 分发。
- **Codex CLI**：hooks 注册 `~/.codex/hooks.json`（需 `config.toml` 里 `[features].hooks=true`），规则注入 `~/.codex/AGENTS.md`。经 `run-hook-codex.sh` 做**输出格式适配**（`decision:block` → `permissionDecision:deny`，`codex_adapter.sh:90-101`）+ apply_patch 载荷归一化。
- 两条路径**共享同一份 hook 快照** `~/.vibeguard/installed/hooks/`。
- **核心差异 / Codex 能力缺口**：Codex 无原生 Read/Glob/Grep hook surface，因此 `analysis-paralysis`（读多不动检测）与 `count_active_constraints` 在 Codex 原生路径**不可用**；文档明确"需要只读探索门禁时用 Claude Code"（`README.md:320-325`）。Codex 侧独有重量级路径 `vibeguard-runtime codex-app-server-wrapper`，在 JSON-RPC 协议层重新实现了 Claude 侧 hook 的部分能力。

### 3.3 vibeguard-runtime（Rust 内核）【事实】

- **定位**：hooks 的高速计算内核，自述 "fast JSON/JSONL ops, hook metrics, Codex app-server guards"（`Cargo.toml:5`）。
- **依赖极简**：仅 `serde_json` + `regex`；edition 2024；release profile `opt-level="z"` + `lto` + `strip`，为体积和启动速度优化（冷启动 ~4ms，`log.sh:64`）。
- **单二进制多子命令**（`main.rs:27-98`），13 个子命令五类能力：JSON 字段提取、日志/事件查询（churn/warn/build-fails/paralysis 计数）、package-rewrite（npm/yarn→pnpm、pip→uv）、hook 输入分类（PASS/SOURCE_NEW/U16_BLOCK 状态码）、session-metrics、**codex-app-server-wrapper（约 2400 行，最大子系统）**。
- **规模**：src 共 6,242 行（生产 ~4,800 + 测试 ~1,400）。最大单文件 `codex_app_server_core.rs` 670 行，已逼近 U-16 800 行硬顶。
- `pkg_rewrite.rs:2` 明说 "Rust is the single runtime implementation" —— **无向后兼容的 Python 版本**（符合用户全局"不做向后兼容"规则）。

### 3.4 Hook 系统内部【事实】

- **I/O 协议**：stdin 读工具事件 JSON（`INPUT=$(cat)`），stdout 输出 decision JSON。
- **全部 hook**（`hooks/manifest.json` 为 source of truth）：pre-bash / pre-edit / pre-write / post-edit / post-write / analysis-paralysis / count_active_constraints / post-build-check / stop-guard / learn-evaluator / pre-commit-guard，各带 profile 与 Codex 支持标记。
- **适配层**：Claude 走 `run-hook.sh` + `policy.sh` 门控；Codex 走 `run-hook-codex.sh`（诊断→apply_patch 归一化→逐行执行→decision 翻译）。
- **运行时绑定 fail-closed**：二进制按 dev-repo → installed snapshot → 同目录三处 fallback 查找，找不到 `exit 2`。

### 3.5 声明式安装契约【事实】

- `schemas/install-modules.json` 把所有组件建模为 `modules`（7 类 kind），每个声明 paths/target/languages/profiles/defaultInstall/cost/stability。
- Profile 用 `extends` 继承叠加；`strict` 与 `full` hook 集相同，差异在运行时策略。
- **原子安装 + 回滚**：先 copy 到 `installed_tmp_XXX`、构建 Rust 二进制、再 `mv` 换入，失败回滚旧快照，隔离开发仓库脏状态。
- **Rust 是硬依赖**：无 Cargo/构建失败直接 `exit 2`，无降级路径。

### 3.6 技术选型评价

【事实】各语言分工：Bash（hook 协议 + 文件系统编排的最短路径）、Python（bash 力不能及的结构化数据，TOML/JSON/settings）、Rust（每个 hook 触发都要跑的热路径，收敛成 ~4ms 二进制）。

【推断，中】混合栈是**务实分层选型**而非技术债堆积——每种语言用在比较优势区间。真正的债在于：
1. **三语言认知负担**：改一条检测逻辑可能要动 Rust（分类）+ Bash（消费状态码）+ manifest（注册）三处，状态码通过换行分隔字符串在 Rust↔Bash 间传递是脆弱隐式契约。
2. **Rust 硬依赖 = 安装门槛 + 单点**：无 Rust 工具链无法安装，二进制缺失所有 hook `exit 2`。
3. **Rust 迁移未完成**：Python 仍散落在 hook 热路径（config 读取、escalation 统计、Codex 适配全部内嵌 `python3 -`）。
4. **Codex 能力两处重复实现**：analysis-paralysis 逻辑既在 bash hook 又在 Rust app-server 策略——是宿主能力差异强加的重复，非设计冗余。
5. **runtime 内部已有拆分压力**：多个 670 行级文件逼近 U-16 硬顶。

---

## 4. 规则体系与学习闭环

### 4.1 规则总量与分类【事实】

`rules/claude-rules/` 下 17 个 `.md`，去重共 **123 条唯一规则 ID**（横幅声称 126，实际由 `claude_md.py` 安装时动态统计，存在轻微漂移，有 `[DRIFT]` 检测提示）：

| 前缀 | 含义 | 数量 |
|---|---|---|
| `U-` | Universal 通用约束 | U-01~U-33 |
| `W-` | Workflow 工作流/调试/验证 | W-01~W-42（非连续） |
| `SEC-` | Security 安全 | SEC-01~SEC-18（缺 15） |
| `RS-` / `TS-` / `GO-` / `PY-` | 语言专属 | 14 / 14 / 12 / 13 |

严重级别：`strict` ×53、`guideline` ×8、`critical` ×2（仅 SEC-01/SEC-02）。

### 4.2 L1-L7 七层与"负向约束"哲学

【事实】L1-L7 是注入 CLAUDE.md 的压缩索引（`README.md:111-117`），全部用负向断言句式（L1 "there is no 'Similar files can be created'"、L4 "no undeclared API/field exists"）。

【推断，中】L1-L7 是**面向 Codex 的压缩摘要层**（Codex 只看 L 层 + Key Detailed Rules 表），Claude 直接加载全量原生规则；L 层与 rule ID 是"一层聚合多条同主题规则"，靠语义归纳而非代码强制。负向绝对句做**认知锚点**压制 LLM 编造倾向，但每条严格规则又配 downgrade path 兜底——刻意用分层化解 U-32 自身警告的"绝对语言制造控制幻觉"。局限：规则文本不可执行，真正约束力在下游 Hook/Guard。

### 4.3 双通道注入 + 过载治理【事实】

- **原生通道**：`rules/claude-rules/{common,rust,...}/` 符号链接到 `~/.claude/rules/vibeguard/`（`claude-home.sh:89,123`）。
- **索引通道**：`~/.claude/CLAUDE.md` 的 `<!-- vibeguard-start/end -->` 标记区注入压缩表。
- **平台 Bug workaround**：用户级 `~/.claude/rules/` 的 YAML 数组 `paths:` 解析 broken（issue #21858），语言规则必须用 CSV 单行无引号格式。
- **元治理 U-32**：`count_active_constraints.py` 阈值 WARN=15 / BLOCK=30，扫描高上下文指令面去重统计，>30 阻断要求分解。W-19（`check_doc_overload.sh`）：CLAUDE.md 非自动生成区 >200 行告警、>800 行失败。

【推断，高】U-32 是整个体系的**元规则**——用规则约束规则数量，防止规则集自身膨胀导致 LLM 忽略。这是 VibeGuard 最独特的设计之一。

### 4.4 静态守卫【事实】

约 28 个可执行守卫，三种实现层级：
1. **grep/正则**（多数 `.sh`，轻量）。
2. **ast-grep**（5 脚本 + 5 `.yml` 规则，语法树匹配）：unwrap / any / console / go-error / config-default。
3. **Python AST**（真正语义分析）：循环依赖、依赖分层、测试完整性、dead shims、SEC-13 MCP 配置扫描。

守卫用 `[RS-03]` 式标签关联回规则 ID。

【推断，高】**并非每条规则都有守卫——123 条规则 vs ~28 守卫，覆盖率约 23%**。守卫只落地可机械检测的规则，其余靠规则文本 + Hook 软约束。设计原则"能写脚本检测就写脚本，不依赖 agent 自觉"，但受可检测性限制。

### 4.5 学习闭环【事实 + 推断】

- `/vibeguard:learn` 双模式：**Mode A 防御式**（错误 → 5-Why 根因 → 生成守卫/hook/规则 → 用原始错误场景验证无回归）；**Mode B 积累式**（非显而易见发现 → 四项质量门 → 提取 SKILL.md）。
- `learn-evaluator` hook（Stop 触发）采集 session metrics + 纠正信号（warn 率 >40%、同文件编辑 5+ 次、correction 事件），**只建议不阻断**。
- **闭环链路**（推断，高）：`错误 → events.jsonl → learn-evaluator 检测 → GC 聚合 learn-digest → /learn 消费 → 生成守卫/规则/skill → 验证 → 注册到 check → 进入 precision-tracker 生命周期`。

### 4.6 规则质量数据（precision-tracker）【事实】

- `data/rule-scorecard.seed.json`：规则生命周期计分卡（stage: experimental→warn→error→demoted→disabled；precision=TP/(TP+FP)）。当前跟踪 11 条规则。
- `scripts/precision-tracker.py`：precision ≥70% & samples ≥20 升 warn；≥90% & ≥50 & 30 天无 FP 升 error（阻断）；<80% 自动降级。

【推断，高】这是借鉴 Semgrep Pro / Clippy 的**规则渐进上线机制**——规则不是一次性写死，而是**数据驱动地演化其强制力**，落地 U-32/W-17。

**⚠ 关键局限【事实】**：`triage.jsonl` 与 scorecard 的 **samples 目前全为 0**，precision 全为 null——FP 追踪机制**框架完备但尚未运转**，学习闭环的数据驱动部分处于"框架就绪、数据待填"状态。

---

## 5. 性能工程

### 5.1 为什么延迟是产品级契约【事实】

`hook-latency-contract.md:3`：hooks 运行在 Claude Code / Codex 会话的**关键路径**上——AI 每次工具调用都过一遍，一个"正确但慢"的 hook 会把每个 agent 动作变成慢操作。因此延迟与正确性同级作为发布门禁。

**P95 预算**（`hook-latency-contract.md:11-21`）：pre-edit/pre-bash=300ms，pre-write=500ms，post-* 系列 400-500ms，stop/learn=400ms。契约声明这是"跨平台 CI 上限"而非理想机优化目标。

### 5.2 三层测量 + 低延迟手段【事实】

- **三层门禁**：① 静态门禁 `validate-hook-perf.sh` 拦昂贵 shell 模式（PERF-01 全量读 JSONL、PERF-02 find 缺 maxdepth、PERF-03 git 无 timeout、PERF-04 循环内 fork）；② 契约自测注入合成慢 hook 要求门禁**必须 FAIL**（自证不是 report-only）；③ 动态基准 `bench_hook_latency.sh --fail-on-regression` 逐 fixture 比对，含 `hotspot=` 归因。
- **低延迟实现**：Rust 二进制承接重活（~4ms）；pre-commit **staged-files-only**（单次 `git diff --cached`，避免 O(n) git 调用）；pre-commit **10s 超时硬保护**；**断路器**抑制批量 warn 噪声；**bounded tail** 读日志（`tail -500`）。

### 5.3 性能风险点【事实 + 推断】

调研初稿曾怀疑仓库提交了一个超预算 4 倍的性能基准样本（`bench-output.json` 中 pre-write-guard P95=2065ms）。

【事实，已核验并推翻】`git ls-files` 显示 `bench-output.json` **未被版本控制跟踪**——它已在 `.gitignore`，是每次 `tests/bench_hook_latency.sh` 本地/CI 运行生成的产物，从未提交。那个 2065ms 是某次本地含 Rust 冷启动的采样，不进仓库、不污染基线。此项**不成立**，保留于此作为"鲜态验证推翻二手结论"的记录。

---

## 6. 测试与 CI 质量

### 6.1 测试体系【事实】

- 框架：**自研 shell 测试框架**（bash + `assert_*`），Python 侧 eval 用 pytest 风格。
- 规模：**73 个测试文件 / ~1345 处断言**（根级 30 + hooks 21 + unit 22）。
- **精度测试**（最有价值资产）：`run_precision.sh` 用 ~80 个正/负 fixture 算 Precision/Recall/F1，CI 门禁要求三者 **≥75**。
- 弱项【推断，中】：Rust runtime 无独立 `cargo test` 步骤出现在 CI（无 `cargo test` job），核心判定逻辑仅靠上层 shell 集成测试**间接覆盖**。

### 6.2 CI 流水线【事实】

`ci.yml` 四个 job：
1. `validate-and-test`（ubuntu+macos 矩阵，20min）：~14 步静态校验 + 文档/路径门禁 + ~30 步回归测试（含 behavior eval / rust guards / setup×3 / precision 阈值 / **hook 性能三件套**）。
2. `windows-smoke`：跨平台契约 smoke（权限位测试在 NTFS 跳过）。
3. `self-application`：VibeGuard 对自己套规则（dogfooding）。
4. `benchmark-report`：**隔离 job + 单独授 contents:write**，注释说明"避免写 token 暴露给 shell-heavy 步骤"——最小权限的成熟供应链姿态。

【推断，高】门禁密度很高（45+ 步），且"自证型"（perf 门禁自带合成慢 hook、精度阈值硬编码 75、behavior eval 阈值 100%）。顶层 `permissions: contents: read` + 写权限隔离是成熟姿态。

### 6.3 评估体系（两套并存）【事实】

- **A. Behavior eval**（零成本执行式）：实际执行 hook 断言 exit_code + JSON path + stdout，阈值 pass/coverage/slice 均 100%。**⚠ 数据集当前仅 2 条样本**——框架完善但覆盖极薄。
- **B. LLM-as-Judge eval**（付费）：调 Claude API 测"Claude+规则"真实检出率，数据集 40 条（tp=36/fp=4），含置信度校准维度。fp 样本仅 4 条，误报评估偏弱。

---

## 7. 演进历史与成熟度

### 7.1 版本演进【事实】

`0.1.0`（2/12 初始 7 层架构）→ `0.3.0`（MCP server + 13 agents + 可观测性）→ `0.5.0`（Rust workspace 10 crates + SEC 规则）→ `1.0.0`（3/14 pre-commit 自动化）→ **`1.1.0`（4/2 Codex CLI 支持 + guard 消息 v2 + **移除 MCP server**）**，当前 tag 到 v1.1.10。

【推断，中】从 0.x "MCP-centric + 多 crate Rust" 到 1.1 "删 MCP、直接 guard、Codex 原生 hook" 是一次**去复杂化重构**——从平台化雄心收敛到轻量可移植的 hook/guard 契约。

### 7.2 文档体系【事实】

根级齐全（README 24KB / CHANGELOG / CONTRIBUTING 16KB / SECURITY / CoC / LICENSE / AGENTS.md），双语（`docs/README_CN.md`），docs/ 约 45 个 md 分区（reference/how/known-issues/internal/vibe），含 asciinema demo。

【推断，高】文档完整度**显著高于同类个人开源项目**。`docs/internal/research/knowledge-discovery/` 说明规则来源有**可追溯证据链**（RSS 采集→四维评分→转化规则）而非凭空写。

### 7.3 平台依赖与已知局限【事实】

`claude-code-known-issues.md` 系统追踪 **10 个平台级 bug** 及 workaround（#21858 YAML paths 解析、#23478 paths 过滤只在 Read 生效、Stop Hook exit 2 无限循环等）。

**根本局限**：
- README/known-issues 都承认 **"grep is not an AST parser"**——guard 重度依赖文本匹配，嵌套作用域会误报。40 天 39,166 事件数据显示 7+ guard 曾误报，2 个被迫禁用（U-HARDCODE 移除、RS-14 一度禁用），迁移路径是 grep → ast-grep。
- 独特局限：**guard 消息会被 AI 字面执行**（TS-03 建议"改用 logger"导致 agent 重构 11 个文件），促成 guard 消息 v2 格式。

### 7.4 社区协作【事实 + 推断】

【事实】License MIT，CoC（Contributor Covenant v2.1），SECURITY.md 完整协调披露政策，双 issue 模板 + PR 模板，CI ubuntu+macos 矩阵，CONTRIBUTING 含完整验证矩阵。

【推断，中】开源治理"仪式完整度"达**中上成熟度**，远超典型个人项目；但**贡献高度集中于单一 maintainer + AI agent**，无外部社区规模化贡献迹象——"治理成熟但社区尚小"。（star/fork/外部 PR 真实规模需线上核实，本地 git 无法确认。）

---

## 8. 竞争定位与独特性

| 对比对象 | VibeGuard 差异 |
|---|---|
| **CLAUDE.md 规则** | 规则会被 AI 忽略；VibeGuard 用 **hook 级实时机械拦截**（`README.md:97`） |
| **普通 linter** | linter 面向人、事后运行；VibeGuard 错误信息是**给 AI 的修复指令**，且在动作**发生前**拦截 |
| **pre-commit hook** | VibeGuard 有 pre-commit，但更广——涵盖会话内 analysis-paralysis、stop-gate 未验证完成、跨会话学习系统 |

【推断，中高】真正护城河不是单个 guard，而是**"三层防御 + 学习闭环 + Harness 原则映射"的体系化** + 对 Claude Code/Codex hook 契约的深度适配。单个 grep guard 可被替代，但"pre-action 拦截 + AI 可消费修复指令 + 从错误自动进化"的组合难以用现成工具拼出。

【推断，中】主要竞争风险来自**平台自身能力增强**——若 Claude Code/Codex 原生提供更强 hook/rule 语义，VibeGuard 的 workaround 价值会被稀释。10 个平台 bug 的追踪恰说明它高度依赖平台契约稳定性（1.1.0 已因平台变化删 MCP）。

---

## 9. 优势 / 风险与不足（综合结论）

### 9.1 核心优势

1. **理念先进且自洽**：把防幻觉从提示层下沉到机械层，且用元规则（U-32/W-17/W-19）约束规则体系自身膨胀，是"会自我进化和自我克制"的防御系统。
2. **性能被当作一等契约**：延迟契约文档化 + 静态/动态/合成三层门禁 + 自证会 FAIL 机制，业内少见。
3. **工程纪律高**：73 测试文件 / ~1345 断言 / ~80 精度 fixture、量化精度门禁（P/R/F1≥75）、CI 最小权限、self-application dogfooding。
4. **文档与治理成熟**：双语、协调披露、录屏 demo、可追溯规则证据链。
5. **UX 克制**：反馈强度分级 + 智能改写 + 从平台 bug 学来的降级设计。

### 9.2 风险与不足

| 优先级 | 问题 | 证据 |
|---|---|---|
| **高** | 学习闭环数据驱动部分"框架就绪、数据待填"——precision-tracker 的 `triage.jsonl`/scorecard samples 全为 0，机制未运转 | `data/triage.example.jsonl`、`rule-scorecard.json` |
| **高** | behavior eval 数据集仅 2 条样本，门禁虽 100% 但覆盖极薄，无法真正回归多数 hook 行为 | `eval/behavior/datasets/v1.jsonl` |
| ~~中~~ 已推翻 | ~~仓库提交了超预算 4 倍的性能基准样本~~ → 核验后 `bench-output.json` 未被跟踪、已 gitignore，此项不成立 | `git ls-files` |
| **中** | Rust runtime 无独立 `cargo test` CI 步骤，核心逻辑仅靠 shell 集成测试间接覆盖 | `ci.yml` 无 cargo test job |
| **中** | Codex 路径能力降级（无 analysis-paralysis 只读探索门禁），防护在 Codex 上不完整 | `README.md:320-325` |
| **中** | 规则守卫覆盖率约 23%（123 规则 vs ~28 守卫），多数规则仍是软约束 | guards/ 统计 |
| **低** | 三语言混合带来认知负担 + Rust 硬依赖安装门槛；CHANGELOG 滞后于 tag（顶部仍 Unreleased，tag 已 v1.1.10） | — |

### 9.3 改进建议（供参考，非要求）

1. **填充学习闭环数据**：让 precision-tracker 真正运转起来（积累 triage 反馈），否则"数据驱动升降级"仍是空转框架。
2. **扩充 behavior eval 数据集**：覆盖每个 native hook × profile × platform 组合，把 100% 门禁变成有意义的回归网。
3. **为 Rust runtime 加 `cargo test` CI job**：核心判定逻辑值得直接覆盖而非间接。（已由 PR #678 落地）
5. **提高守卫覆盖 / 明确"软约束"边界**：对暂无守卫的严格规则，用文档标注"仅规则文本约束"，避免用户误以为有机械强制。

---

## 附录：关键文件索引

- 定位/理念：`README.md`、`docs/README_CN.md`
- 演进：`CHANGELOG.md`、平台 bug 追踪 `docs/reference/claude-code-known-issues.md`、根因/路线 `docs/known-issues/systemic-issues-report.md`
- 安装契约：`schemas/install-modules.json`、`scripts/setup/install.sh`、`hooks/manifest.json`
- Rust 运行时：`vibeguard-runtime/src/main.rs`、`codex_app_server.rs`、`pkg_rewrite.rs`、`hook_checks.rs`
- Hook 适配：`hooks/run-hook.sh`、`run-hook-codex.sh`、`hooks/_lib/codex_adapter.sh`、`hooks/log.sh`、示例 `hooks/pre-write-guard.sh`
- 规则/注入：`rules/claude-rules/**`、`claude-md/vibeguard-rules.md`、`scripts/lib/claude_md.py`、`scripts/constraints/count_active_constraints.py`
- 守卫：`guards/{universal,rust,go,typescript,python,ast-grep-rules}/`、`sgconfig.yml`
- 学习/质量：`.claude/commands/vibeguard/learn.md`、`hooks/learn-evaluator.sh`、`data/rule-scorecard.seed.json`、`scripts/precision-tracker.py`
- 性能/测试/CI：`docs/reference/hook-latency-contract.md`、`tests/bench_hook_latency.sh`、`tests/run_precision.sh`、`.github/workflows/ci.yml`、`eval/`
