---
name: "VibeGuard: Preflight"
description: "在重大修改前探索项目，生成约束集，从源头预防问题"
category: VibeGuard
tags: [vibeguard, preflight, constraints, prevention]
---

<!-- VIBEGUARD:PREFLIGHT:START -->
**核心理念**
- 问题在写代码前预防，比写完后检测修复成本低 10 倍
- 产出的是**约束集**（不可做清单），不是信息堆砌
- 约束集指导后续所有编码，让实现阶段不需要做架构决策
- 每条约束必须可验证 — 要么能写 guard 脚本检测，要么能写测试断言

**复杂度路由**（自动判断流程深度）

| 规模 | 流程 | 行动 |
|------|------|------|
| 1-2 文件 | 直接实现 | 跳过 preflight，直接编码 |
| 3-5 文件 | 轻量 preflight | 执行下方步骤 1-5，生成约束集 |
| 6+ 文件 | 完整规划 | 先 `/vibeguard:interview` 生成 SPEC → 再执行 preflight |

**触发条件**（3+ 文件级别）
- 涉及 3+ 文件的改动
- 新增入口点（binary / service / CLI subcommand）
- 修改数据层（数据库、缓存、文件存储）
- 跨模块重构

**Guardrails**
- 不做任何代码修改，只读和分析
- 不猜测 — 不确定的标记为 `[UNCLEAR]`，后续用 AskUserQuestion 确认
- 约束集必须展示给用户确认后才能开始编码

**Steps**

1. **识别项目类型和结构**
   - 检测语言/框架（Cargo.toml → Rust, package.json → TS/JS, pyproject.toml → Python）
   - 识别 monorepo / workspace 结构（workspace members / packages / apps）
   - 列出所有入口点（bin crate、main.ts、app.py、CLI commands）
   - 输出：`项目概览`（语言、框架、入口点列表）

2. **映射共享资源**
   - 搜索所有数据路径构造（`data_dir`, `db_path`, `config_path`, `.join("xxx.db")`）
   - 搜索所有环境变量读取（`env::var`, `process.env`, `os.environ`）
   - 搜索所有端口/地址绑定（`listen`, `bind`, `PORT`）
   - 识别共享状态（全局单例、共享数据库、消息队列）
   - 输出：`共享资源地图`（哪些资源被哪些入口使用）

3. **提取现有模式**
   - 错误处理模式（Result vs unwrap, try-catch 风格）
   - 类型定义位置（core/ vs 各 app 各自定义）
   - 命名规范（snake_case/camelCase, 前缀规律）
   - 模块职责划分（哪个模块管什么）
   - 输出：`模式清单`

4. **运行静态守卫获取基线**
   - 根据语言选择对应的 vibeguard 守卫脚本：
     - **Rust**: `check_unwrap_in_prod.sh`, `check_duplicate_types.sh`, `check_nested_locks.sh`, `check_workspace_consistency.sh`
     - **Python**: `check_duplicates.py`, `check_naming_convention.py`, `test_code_quality_guards.py`
     - **TypeScript**: `check_any_abuse.sh`, `check_console_residual.sh`
   - 记录当前违规数量作为基线（修改后不能增加）
   - 输出：`守卫基线`

   **[Stop] 展示基线数据，等待用户确认后再生成约束集。**
   - 展示步骤 1-4 的所有发现
   - 用 AskUserQuestion 让用户确认基线数据和项目理解是否正确
   - 如有 `[UNCLEAR]` 项，必须在此处用 AskUserQuestion 确认

5. **生成约束集**

   基于步骤 1-4 的发现，为当前任务生成约束集。每条约束格式：

   ```
   [C-XX] 约束描述
   来源：步骤 N 发现的具体证据
   验证：如何检查是否违反（guard 脚本 / 测试 / 人工检查）
   ```

   **必须覆盖的约束类别**：

   | 类别 | 约束目标 | 示例 |
   |------|----------|------|
   | 数据收敛 | 所有入口的数据路径必须收敛 | "所有入口通过 `core::resolve_db_path()` 获取 DB 路径" |
   | 类型唯一 | 不新增与现有类型重名的定义 | "禁止在 app 层重新定义 core 已有的 SearchQuery" |
   | 接口稳定 | 不破坏公开 API 签名 | "ItemId::from(&str) 签名不变" |
   | 错误处理 | 保持与项目一致的错误处理风格 | "非测试代码禁止 unwrap()，使用 ? 或 map_err" |
   | 命名一致 | 遵循项目已有命名规范 | "环境变量统一使用 REFINE_ 前缀" |
   | 守卫基线 | 修改后违规数不增加 | "unwrap 数 ≤ 50, 重复类型 ≤ 2" |

6. **输出约束集报告**

   将约束集以结构化格式输出：

   ```markdown
   # VibeGuard Preflight 约束集

   ## 项目：<项目名>
   ## 任务：<用户描述的任务>
   ## 日期：<当前日期>

   ## 约束清单

   ### 数据收敛
   - [C-01] ...

   ### 类型唯一
   - [C-02] ...

   ### 守卫基线
   - [C-XX] 修改前基线：unwrap=50, duplicates=2, nested_locks=0
     修改后必须：unwrap ≤ 50, duplicates ≤ 2, nested_locks = 0

   ## 需要用户确认的问题
   - [UNCLEAR] ...
   ```

7. **用户确认**
   - 展示完整约束集
   - 用 AskUserQuestion 确认 `[UNCLEAR]` 项
   - 用户确认后，约束集成为后续编码的硬约束

**后续使用**
- 编码过程中，每次修改前对照约束集自检
- 编码完成后，运行 `/vibeguard:check` 验证守卫基线未恶化
- 约束集中的每条规则都是不可违反的 — 如需违反，必须先更新约束集并获得用户同意

**Reference**
- VibeGuard 守卫脚本：`vibeguard/guards/`
- VibeGuard 规则：`vibeguard/rules/`
- VibeGuard 七层防幻觉框架：`vibeguard/spec.md`
<!-- VIBEGUARD:PREFLIGHT:END -->
