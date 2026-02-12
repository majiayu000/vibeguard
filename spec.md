# VibeGuard 规范 — AI 辅助开发防幻觉框架

> 版本: 1.0 | 更新日期: 2026-02-12

## 1. 设计哲学

### 1.1 核心洞察：反转传统防线

传统代码质量关注"开发者不犯错"；VibeGuard 关注"AI 辅助开发不产生幻觉"。

LLM 的主要失效模式不是语法错误（IDE 能捕获），而是：
- **凭空捏造**：发明不存在的 API、文件路径、数据字段
- **重复造轮子**：不搜索就新建，导致同一功能多份实现
- **命名混乱**：混用 camelCase/snake_case，创建别名
- **空壳交付**：生成看起来正确但数据为空/硬编码的页面
- **过度设计**：添加不需要的抽象、兼容层、deprecated 标记

### 1.2 核心原则

```
防幻觉 = 约束输入 + 验证输出 + 自动拦截
```

| 原则 | 含义 |
|------|------|
| 数据驱动 | 没有数据就显示空白，永远不用假数据 |
| 先搜后写 | 新建任何东西前必须搜索已有实现 |
| 单一命名 | 一个概念一个名字，禁止别名 |
| 最小改动 | 只做被要求的事，不添加额外"改进" |
| 自动拦截 | CI 守卫自动阻断已知失效模式 |

---

## 2. 七层防御架构

```
┌─────────────────────────────────────────────────────────┐
│ Layer 7: 周度复盘（人工）                                 │
│   — 回顾回归事件、更新规则、调整指标目标                    │
├─────────────────────────────────────────────────────────┤
│ Layer 6: Prompt 内嵌规则（LLM 行为约束）                  │
│   — CLAUDE.md / Codex instructions 中的强制规则           │
├─────────────────────────────────────────────────────────┤
│ Layer 5: Skill / Workflow（执行流程约束）                  │
│   — plan-folw / fixflow / optflow / vibeguard skill      │
├─────────────────────────────────────────────────────────┤
│ Layer 4: 架构守卫测试（AST 级自动检测）                    │
│   — test_code_quality_guards.py 五条核心规则              │
├─────────────────────────────────────────────────────────┤
│ Layer 3: Pre-commit Hooks（提交前拦截）                   │
│   — 命名检查、重复检查、secret 扫描、linting              │
├─────────────────────────────────────────────────────────┤
│ Layer 2: 命名约束系统（snake_case 强制）                  │
│   — check_naming_convention.py + 边界转换规范             │
├─────────────────────────────────────────────────────────┤
│ Layer 1: 反重复系统（先搜后写强制）                        │
│   — check_duplicates.py + SEARCH BEFORE CREATE 规则       │
└─────────────────────────────────────────────────────────┘
```

### Layer 1: 反重复系统

**意图**：阻止 LLM 最常见的失效模式——不搜索就新建。

**规则**：
1. 新建文件/类/Protocol/函数前，必须先搜索项目中是否已有类似功能
2. 已有就扩展，不新建
3. 跨模块共享的接口放 `core/interfaces/`
4. 跨模块共享的工具函数放 `core/`
5. 第三次重复时必须抽象

**检测工具**：`check_duplicates.py`
- 扫描 Protocol 定义重复
- 扫描同名类跨文件
- 扫描同名模块级函数
- 支持 `--strict` 模式（CI 阻断）

**缺口**：
- 仅检测名称重复，不检测语义重复（两个功能相似但名称不同的函数）
- 升级路径：集成 LLM 语义相似度分析

### Layer 2: 命名约束系统

**意图**：消除 Python 内部混用 camelCase 的问题。

**规则**：
- Python 内部一律 snake_case
- API 边界（请求/响应/快照）使用 camelCase
- 入口用 `snakeize_obj()` 转换，出口用 `camelize_obj()` 转换
- 禁止函数/类别名

**检测工具**：`check_naming_convention.py`
- 检测已知 camelCase 键名在 Python 代码中的直接使用
- 支持路径豁免（API 输出、测试文件、前端数据构建等）
- 支持上下文豁免（Pydantic alias、camelize_obj 调用等）

**缺口**：
- 仅检查已知键名列表，无法捕获新增的 camelCase 键
- 升级路径：改为 AST 级检测，匹配 `dict.get("camelCase")` 通用模式

### Layer 3: Pre-commit Hooks

**意图**：在代码到达仓库前拦截基础问题。

**检测项**：
| Hook | 功能 |
|------|------|
| trailing-whitespace | 删除尾部空格 |
| end-of-file-fixer | 确保文件以换行结尾 |
| check-yaml/json/toml | 验证配置文件格式 |
| check-added-large-files | 阻止大文件（>1MB）提交 |
| detect-private-key | 检测私钥泄漏 |
| ruff | Python linting + formatting |
| check-naming-convention | snake_case 强制 |
| shellcheck | Shell 脚本质量 |
| gitleaks | Secret 扫描 |
| conventional-pre-commit | 提交信息规范 |

**缺口**：
- TypeScript 守卫依赖前端构建环境
- 升级路径：独立的 TS 守卫脚本，不依赖 `bun run lint`

### Layer 4: 架构守卫测试

**意图**：AST 级自动检测五种 AI vibe-coding 回归模式。

**五条核心规则**：

| # | 规则 | 检测方式 |
|---|------|----------|
| 1 | 禁止静默吞异常 | AST 检查 except 块是否有 logging/re-raise |
| 2 | Facade 禁止 Any 类型 | AST 检查公开方法参数和返回值 |
| 3 | 禁止 Re-export Shim | AST 检查文件是否只有 import + `__all__` |
| 4 | 禁止跨模块私有属性访问 | 正则检查 `xxx._private` 模式 |
| 5 | 禁止重复 Protocol 定义 | 正则扫描同名 Protocol 跨文件 |

**配置方式**：
- `APP_ROOT`: 项目根目录
- `APPLICATION_DIRS` / `WORKFLOW_DIRS`: 被扫描的目录列表
- `_PRIVATE_ACCESS_ALLOWLIST`: 已知技术债豁免列表
- `_DUPLICATE_PROTOCOL_ALLOWLIST`: 允许重复的 Protocol 列表

**缺口**：
- 规则 5 仅检测 Protocol，不检测普通接口重复
- 升级路径：扩展到 ABC、TypedDict 等接口类型

### Layer 5: Skill / Workflow

**意图**：用结构化流程约束 AI 的执行路径。

| Skill | 功能 |
|-------|------|
| `vibeguard` | 完整防幻觉规范查阅 |
| `plan-folw` | 冗余分析 → 计划构建 → 步骤执行 |
| `fixflow` | 工程交付流（计划 → 执行 → 测试 → 提交） |
| `optflow` | 优化发现与执行 |
| `plan-mode` | 结构化计划生成与文件落地 |

**关键约束**：
- 每个 workflow 都要求"先分析/计划，再执行"
- 每步必须有测试证据
- 状态机严格：`pending → in_progress → completed`
- 同时只能有一个 `in_progress` 步骤

**缺口**：
- workflow 之间有 BDD 重复内容
- 升级路径：提取共享的 BDD 模块

### Layer 6: Prompt 内嵌规则

**意图**：在 LLM 的 system prompt 中植入强制规则。

**规则来源**：`~/.claude/CLAUDE.md`（全局）和项目 `CLAUDE.md`

**关键规则**：
- 不做向后兼容
- 不硬编码
- 不创建别名
- 先搜后写
- 第三次重复必须抽象
- spec-driven workflow（3+ 文件变更先写 spec）

**缺口**：
- 规则分散在全局和项目两处，不易同步
- 升级路径：VibeGuard 统一管理，setup.sh 部署

### Layer 7: 周度复盘

**意图**：人工闭环，从回归事件中提炼新规则。

**复盘内容**：
1. 本周回归事件（失效防线、根因、新增规则）
2. 守卫拦截统计（拦截次数、典型案例）
3. 指标趋势
4. 下周重点

**缺口**：
- 目前纯手动，无自动化指标采集
- 升级路径：`metrics_collector.sh` 自动采集基础指标

---

## 3. 量化指标体系

### 3.1 核心指标

| # | 指标 | 定义 | 目标 | 采集方法 |
|---|------|------|------|----------|
| M1 | 回归密度 | 每 100 次提交中出现的 AI 幻觉回归次数 | < 2 | `git log` + 手动标记 |
| M2 | 守卫拦截率 | pre-commit + test 阻断的违规次数 / 总违规次数 | > 80% | pre-commit 日志 + CI 报告 |
| M3 | 重复代码率 | `check_duplicates.py` 报告的重复组数 | < 5 组 | `check_duplicates.py` 输出 |
| M4 | 命名违规率 | `check_naming_convention.py` 报告的问题数 | 0 | `check_naming_convention.py` 输出 |
| M5 | 架构守卫通过率 | `test_code_quality_guards.py` 通过的规则数 / 总规则数 | 100% | pytest 输出 |

### 3.2 采集频率

| 指标 | 频率 | 触发方式 |
|------|------|----------|
| M1 | 周度 | 人工复盘时统计 |
| M2 | 每次提交 | pre-commit hook 自动记录 |
| M3 | 每次运行 | `check_duplicates.py` |
| M4 | 每次提交 | pre-commit hook |
| M5 | 每次 CI | pytest 自动运行 |

### 3.3 告警阈值

| 指标 | 黄色告警 | 红色告警 |
|------|----------|----------|
| M1 | > 2 次/周 | > 5 次/周 |
| M2 | < 80% | < 60% |
| M3 | > 5 组 | > 10 组 |
| M4 | > 0 | > 5 |
| M5 | < 100% | < 80% |

---

## 4. 执行模板

### 4.1 任务启动 Checklist

每个开发任务启动前必须确认：

```yaml
task_contract:
  required:
    - objective: "明确的可验证目标"
    - data_source: "数据来源（文件/API/数据库）"
    - acceptance: "验收标准（至少 1 条可测试）"
  forbidden:
    - "先写再说"
    - "大概/可能/应该能行"
    - "直接复制一份"
  warnings:
    - no_search_before_create: "新建文件/类/函数前未搜索已有实现"
    - no_test_evidence: "步骤完成但无测试证据"
    - large_diff: "单步超过 300 行净变更"
```

### 4.2 计划文件模板

见 `workflows/plan-folw/references/plan-template.md`

### 4.3 复盘报告模板

见 `skills/vibeguard/references/review-template.md`

### 4.4 CI 配置建议

```yaml
# GitHub Actions 示例
- name: Run architecture guards
  run: pytest tests/architecture/test_code_quality_guards.py -v

- name: Check duplicates
  run: python scripts/check_duplicates.py --strict

- name: Check naming convention
  run: python scripts/check_naming_convention.py app/
```

---

## 5. 资产拓扑图

```
vibeguard/
├── spec.md                             # 本文件（~500行）- 完整规范
├── README.md                           # 快速开始（~50行）
├── setup.sh                            # 一键部署（~30行）
│
├── claude-md/
│   └── vibeguard-rules.md              # CLAUDE.md 追加段落（~150行）
│
├── skills/vibeguard/
│   ├── SKILL.md                        # 完整规范 Skill（~100行）
│   └── references/
│       ├── task-contract.yaml          # 任务启动 Checklist
│       ├── review-template.md          # 周度复盘模板
│       └── scoring-matrix.md           # risk-impact 评分矩阵
│
├── workflows/
│   ├── plan-folw/                      # 冗余分析 + 计划构建
│   │   ├── SKILL.md
│   │   ├── references/
│   │   │   ├── analysis-playbook.md
│   │   │   ├── risk-impact-scoring.md
│   │   │   ├── plan-template.md
│   │   │   └── plan-accomplishments.md
│   │   └── scripts/
│   │       ├── redundancy_scan.sh
│   │       ├── findings_to_plan.py
│   │       └── plan_lint.py
│   ├── fixflow/SKILL.md                # 工程交付流
│   ├── optflow/SKILL.md                # 优化发现与执行
│   └── plan-mode/SKILL.md              # 计划落地
│
├── guards/
│   ├── python/
│   │   ├── test_code_quality_guards.py # 通用版架构守卫
│   │   ├── check_naming_convention.py  # 通用版命名检查
│   │   ├── check_duplicates.py         # 通用版重复检查
│   │   └── pre-commit-config.yaml      # pre-commit 模板
│   └── typescript/
│       └── eslint-guards.ts            # TS 守卫模板
│
├── project-templates/
│   ├── python-CLAUDE.md                # Python 项目 CLAUDE.md 模板
│   ├── typescript-CLAUDE.md            # TS 项目 CLAUDE.md 模板
│   └── rust-CLAUDE.md                  # Rust 项目 CLAUDE.md 模板
│
└── scripts/
    ├── compliance_check.sh             # 合规检查
    └── metrics_collector.sh            # 指标采集
```

---

## 6. 实战案例

### 案例 1: Pro Forma 空表头

**症状**：Pro Forma 页面列标题显示 `1, 2, 3, 4, 5` 而非实际年份日期。

**根因**：Excel 解析器使用了通用数字标签，未提取实际日期行作为列头。

**失效防线**：Layer 4（架构守卫没有覆盖数据准确性）

**修复**：修改 header 提取逻辑，使用 date rows 替代 generic numeric labels。

**新增规则**：无（数据准确性需要集成测试覆盖，不适合 AST 守卫）。

**教训**：AST 守卫无法捕获语义错误，需要配合数据验证测试。

### 案例 2: 命名不匹配

**症状**：Python 内部使用 `data.get("askingPrice")` 而非 `data.get("asking_price")`，
导致在 snakeize_obj 转换后取值为 None。

**根因**：LLM 直接从 API 文档复制 camelCase 键名，未通过 snakeize_obj 转换。

**失效防线**：Layer 2（check_naming_convention.py 成功拦截）

**修复**：在数据入口添加 `snakeize_obj()` 调用。

**新增规则**：将 `askingPrice` 加入 `KNOWN_CAMEL_KEYS` 字典。

**教训**：守卫必须持续更新已知键名列表。

### 案例 3: 别名混用

**症状**：代码库中同时存在 `format_percent` 和 `format_percentage`，
部分调用方使用旧名导致 ImportError。

**根因**：LLM 创建了函数别名 `format_percent = format_percentage` 作为"向后兼容"。

**失效防线**：Layer 6（CLAUDE.md 中的"禁止别名"规则阻止了此模式）

**修复**：选择 `format_percentage` 作为规范名，全局替换调用方，删除别名。

**新增规则**：在 `check_duplicates.py` 中检测模块级别名赋值。

**教训**：LLM 倾向于创建兼容层而非直接修改。

### 案例 4: 空页面交付

**症状**：生成的 OM 文档中 Property Highlights 页面为空白。

**根因**：card builder 使用了 `hero_image_url`（建筑照片）而非 `amenities_map_url`（地图），
导致未找到数据时返回空页面。

**失效防线**：Layer 6（CLAUDE.md 中明确了 `amenities_map_url` 的使用规则）

**修复**：修正 card builder 中的数据源引用。

**新增规则**：在 CLAUDE.md 中添加显式的 Page Type → 数据源映射。

**教训**：LLM 倾向于使用"看起来合理"的字段名而非查阅文档。

---

## 7. 缺口与路线图

### 7.1 当前缺口

| # | 缺口 | 影响 | 优先级 |
|---|------|------|--------|
| G1 | 语义重复检测（名称不同但功能相似） | 无法捕获变体重复 | P1 |
| G2 | 自动化指标采集 | 复盘依赖人工统计 | P1 |
| G3 | TypeScript 守卫 | TS 代码缺少架构守卫 | P2 |
| G4 | 运行时数据验证 | 空页面问题需要集成测试 | P2 |
| G5 | Workflow BDD 模块去重 | fixflow/optflow 中 BDD 段落重复 | P3 |

### 7.2 路线图

**Phase 1（当前）**：
- 建立 VibeGuard 仓库，集中管理所有防幻觉资产
- setup.sh 一键部署到 ~/.claude/ 和 ~/.codex/
- 通用化守卫模板，支持新项目快速接入

**Phase 2（下一步）**：
- 自动化指标采集（`metrics_collector.sh`）
- TypeScript 架构守卫（`eslint-guards.ts`）
- Rust 项目模板和守卫

**Phase 3（未来）**：
- LLM 辅助的语义重复检测
- 集成测试数据验证框架
- 跨项目指标仪表板

---

## 附录 A: 术语表

| 术语 | 含义 |
|------|------|
| 幻觉 (Hallucination) | LLM 生成看起来正确但实际错误的输出 |
| Vibe Coding | 依赖 LLM "感觉"编码而非验证的开发方式 |
| 守卫 (Guard) | 自动检测并阻断违规的测试或脚本 |
| 回归 (Regression) | 之前正确的功能因新改动而失效 |
| AST | Abstract Syntax Tree，抽象语法树 |
| Pre-commit Hook | Git 提交前自动运行的检查脚本 |
| DoR | Definition of Ready，就绪定义 |
| BDD | Behavior-Driven Development，行为驱动开发 |

## 附录 B: 参考资料

- [Keep a Changelog](https://keepachangelog.com/)
- [Semantic Versioning](https://semver.org/)
- [Conventional Commits](https://www.conventionalcommits.org/)
- [Ruff](https://docs.astral.sh/ruff/) - Python linting
- [Gitleaks](https://gitleaks.io/) - Secret scanning
- [ShellCheck](https://www.shellcheck.net/) - Shell script analysis
