---
name: auto-optimize
description: 对目标项目进行自动化分析、评估、设计和优化。整合 VibeGuard 守卫作为基线扫描，修复过程遵守 VibeGuard 规范，收尾时运行合规检查。支持 auto-run-agent 自主执行。
---
# Auto-Optimize：自主优化流程

整合 VibeGuard 守卫体系的项目自主优化工作流。

## 核心原则（从 30+ 实战 session 提炼）

1. **不修比乱修重要** — 每个发现必须分类为 FIX / SKIP / DEFER，SKIP 必须附理由
2. **扫描维度轮换** — 不要每次只找同一类问题，按维度轮换扫描
3. **原子验证** — 每个 fix 独立验证，不攒到最后一起跑
4. **经验持久化** — 踩过的坑写入 MEMORY.md，避免跨 session 重复犯错
5. **守卫优先** — 先跑 VibeGuard 确定性守卫获取基线，再用 LLM 深度扫描

## 扫描维度（按轮次轮换）

| 轮次 | 维度 | 扫描目标 |
|------|------|----------|
| 1 | Bug | 逻辑错误、死锁、TOCTOU、panic 路径、边界条件 |
| 2 | 架构 | 命名冲突、职责混乱、模块耦合、类型设计缺陷 |
| 3 | 重复 | 代码重复、可提取的公共逻辑、copy-paste 痕迹 |
| 4 | 性能 | 不必要的 clone/alloc、O(n²) 路径、阻塞调用 |
| 5 | 测试 | 缺失覆盖、脆弱断言、缺少边界用例 |
| 6 | API | 对标竞品的功能缺口、易用性问题、文档缺失 |
| 7 | 一致性 | 多入口数据路径收敛、环境变量统一、配置默认值对齐、共享状态 schema 一致 |

用户可指定维度，否则按项目当前状态自动选择最需要的维度。

## 完整流程

### Phase 1：探索与评估（整合 VibeGuard 守卫）

1. 确认目标项目路径（用户提供或当前目录）
2. 深度探索项目：
   - 读取 README、CLAUDE.md 等项目规范
   - 分析项目结构、技术栈、依赖
   - 阅读核心源码，理解架构
   - 检查 TODO/FIXME、#[allow(dead_code)] 等标记
3. **运行 VibeGuard 守卫获取基线**（按项目语言选择）：
   ```bash
   # Python 项目
   python guards/python/test_code_quality_guards.py    # 架构守卫
   python guards/python/check_naming_convention.py app/ # 命名检查
   python guards/python/check_duplicates.py app/        # 重复检测

   # 如果项目已集成守卫（tests/architecture/ 或 scripts/）
   pytest tests/architecture/ -v                        # 直接用项目内守卫
   python scripts/check_duplicates.py --strict
   python scripts/check_naming_convention.py app/
   ```
4. 按当前维度并行扫描（用 sub-agent 按模块分区扫描，加载 `rules/` 对应语言规则）
5. **合并守卫结果 + LLM 扫描结果**，输出评估报告给用户，确认优化方向

### Phase 2：分类与设计（遵守 VibeGuard 规范）

对每个发现进行三分类：

```
FIX  — 有明确方案，不破坏公开 API，收益 > 风险
SKIP — 附理由：breaking change / over-engineering / not a bug / intentional design
DEFER — 需要更多信息或用户决策，记录到 TASKS.md 的 backlog 区
```

SKIP 判断标准（加载 rules/ 目录下对应语言的规则 + VibeGuard 规范）：
- 触及公开 API 签名 → SKIP（除非用户明确要求 breaking change）
- 只有 1 处使用的"重复" → SKIP（提取抽象是过度设计 — VibeGuard Layer 5 最小改动）
- 不同语义的相似代码 → SKIP（如 Span 内联样式 vs Text 全局样式）
- 宏能解决但会降低可读性 → SKIP
- 新建文件/类/函数前未搜索已有实现 → 违反 VibeGuard Layer 1，先搜后写

FIX 任务按依赖排序，生成结构化任务列表：
```markdown
## 高优先级
- [ ] [BUG] 描述 | 文件 | 方案摘要
- [ ] [BUG] ...

## 中优先级
- [ ] [DEDUP] 描述 | 文件 | 方案摘要
- [ ] [DESIGN] ...

## 架构审查（高/中完成后触发）
- [ ] [ARCH] 全面审查架构合理性，发现问题追加新任务

## 低优先级
- [ ] [STYLE] ...

## Backlog（DEFER）
- [ ] [DEFER] 描述 | 需要的信息
```

### Phase 3：创建 Runner 环境

1. 在目标项目中 commit 当前状态并创建新分支（如 `auto-optimize`）
2. 创建 runner 目录结构：
```
<runner-dir>/
├── memory/
│   ├── TASKS.md      # Phase 2 设计的任务列表
│   ├── CONTEXT.md    # 项目背景、技术栈、规范、架构概览
│   └── DONE.md       # 自动生成
├── workspace/        # 软链接到目标项目
├── logs/
└── config.yaml
```

3. CONTEXT.md 必须包含：
   - 项目概述和技术栈
   - 架构概览（关键模块和职责）
   - 项目规范（引用项目自身的 CLAUDE.md 或编码规范）
   - **VibeGuard 规范引用**（提醒 worker 遵守先搜后写、命名约束、最小改动等规则）
   - 构建和测试命令（每次修改后必须验证）
   - commit 规范（如有 DCO 要求等）
   - 当前扫描维度和轮次记录

4. config.yaml 默认配置：
```yaml
max_iterations: 50
max_cost_usd: 0
max_duration: 6h
consecutive_no_progress: 3
stop_when_empty: true
cooldown_duration: 15s
worker_timeout: 30m
use_git_detection: true
```

5. runner 目录默认路径：`~/<project-name>-runner/`

### Phase 4：执行与验证

**前提检查**：`AUTO_RUN_AGENT_DIR` 环境变量必须设置且目录存在。

```bash
# 检测 auto-run-agent
if [[ -z "${AUTO_RUN_AGENT_DIR:-}" ]]; then
  echo "AUTO_RUN_AGENT_DIR 未设置，跳过 Phase 4"
  echo "设置方法：export AUTO_RUN_AGENT_DIR=/path/to/auto-run-agent"
  exit 0
fi
```

1. 使用 auto-run-agent 启动：
```bash
cd "${AUTO_RUN_AGENT_DIR}"
./orchestrator --dir <runner-dir> --max-iterations 50 --max-cost 0 --max-duration 6
```
2. Worker 执行规则：
   - 每个 fix 完成后立即运行验证命令（从 CONTEXT.md 读取）
   - 验证失败 → 立即回滚该 fix，标记为 DEFER，继续下一个
   - 验证通过 → commit，标记为 DONE，更新 DONE.md
   - 每完成一个 fix，检查是否触发了新问题（回归检测）
3. 监控命令：
   - `tail -f <runner-dir>/logs/orchestrator_*.log` — 实时日志
   - `cat <runner-dir>/memory/DONE.md` — 查看完成记录
   - `cat <runner-dir>/memory/TASKS.md` — 查看剩余任务

> **注意**：Phase 1-3 不依赖 auto-run-agent，可在无 agent 环境下独立使用（手动执行 TASKS.md）。

### Phase 5：收尾与学习（VibeGuard 合规检查）

1. 所有 FIX 完成后，运行完整测试套件
2. **运行 VibeGuard 合规检查**：
   ```bash
   bash ~/Desktop/code/AI/tools/vibeguard/scripts/compliance_check.sh /path/to/project
   ```
3. 修复合规检查发现的问题（如有）
4. bump version（patch for fixes, minor for new features）
5. 更新项目 MEMORY.md，记录本轮发现的模式和教训
6. 记录本轮扫描维度，下次自动切换到下一个维度

## 规则系统

规则文件位于 `rules/` 目录，按语言分类。扫描时自动加载对应语言的规则。

```
auto-optimize/
├── SKILL.md
└── rules/
    ├── universal.md   ← 通用规则（所有语言适用）
    ├── python.md      ← Python 特定规则（含 VibeGuard 守卫交叉引用）
    ├── rust.md        ← Rust 特定规则
    ├── typescript.md  ← TypeScript 特定规则
    └── go.md          ← Go 特定规则
```

规则格式：每条规则有 ID、类别、描述、示例。Worker 在扫描和修复时参考这些规则来判断 FIX/SKIP。

**与 VibeGuard guards/ 的关系**：
- `guards/` = 确定性检测工具（AST 脚本，集成到 CI/pre-commit）
- `rules/` = LLM 扫描参考（Markdown，指导 worker 判断 FIX/SKIP/DEFER）
- 重叠部分（如 PY-02 裸异常）通过交叉引用处理，不合并

## 用户交互要点
- Phase 1 完成后必须向用户展示评估报告（含守卫基线 + LLM 扫描结果），确认优化方向
- Phase 2 的任务列表展示给用户确认后再创建文件
- 启动前询问用户：迭代次数、时间限制、是否有成本限制
- 用户可随时编辑 TASKS.md 插入新任务或调整优先级

## 注意事项
- `AUTO_RUN_AGENT_DIR` 环境变量指定 auto-run-agent 路径，Phase 4 运行时检测
- 目标项目必须先 commit 干净再切分支，确保可回滚
- workspace 用软链接，不复制代码
- 多个项目可同时运行，互不影响（注意 API rate limit）
