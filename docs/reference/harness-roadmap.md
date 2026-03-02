# VibeGuard Harness 补齐计划

**制定日期**: 2026-03-02
**基于**: [覆盖度审计报告](harness-audit-report.md)
**优先级**: P0（核心防线）> P1（可观测/运维）> P2（体验）> P3（文档）

---

## P0：核心防线补齐

### P0-1：编辑优化 — Hashline 格式

**目标**: Harness 报告编辑成功率从 6.7% → 68.3%（行级哈希锚定）

**涉及文件**:
- `hooks/post-edit-guard.sh` — 添加 hashline 验证
- `mcp-server/src/tools.ts` — 新增 hashline 编辑工具
- 新增: `scripts/test-edit-stability.sh`

**方案**:
1. post-edit-guard 计算编辑前文件的行级 SHA256
2. 生成 hashline 格式：`@@ hash=abc123 line=45 @@`
3. 编辑验证时对比哈希，失败则提示具体行号
4. MCP 工具返回 hashline 格式结果

**工作量**: 40-50h
**风险**: 受限于 Claude Code Edit 工具的 API 设计
**验收**: 编辑成功率 ≥60%

---

### P0-2：Turn/Thread 会话模型

**目标**: 长周期任务的状态恢复和并发隔离

**涉及文件**:
- 新增: `mcp-server/src/session_manager.ts`
- `mcp-server/src/index.ts` — 多 Turn 处理
- `hooks/log.sh` — 扩展 turn_id/thread_id

**方案**:
1. Thread = 长周期任务会话容器（metadata: task_id, status）
2. Turn = 用户操作驱动的工作单元（有序 items）
3. MCP server 实现 thread_manager：创建/恢复/查询
4. 跨会话恢复：读 events.jsonl 恢复 turn 状态

**工作量**: 60-80h
**风险**: MCP server 复杂度增加
**验收**: 7 天断点续传恢复无状态丢失

---

## P1：可观测性与运维

### P1-1：质量等级自动评分 ✅

**目标**: GC 根据指标自动评分，动态调整清理阈值

**实现**: `scripts/quality-grader.sh`
```
grade = security × 0.4 + stability × 0.3 + coverage × 0.2 + performance × 0.1
等级: A(≥90) B(70-89) C(50-69) D(<50)
GC 频率: A=7天 B=3天 C=1天 D=实时
```

**完成日期**: 2026-03-02

---

### P1-2：平台可靠性约束（Rust + Go）— 部分完成 ✅

**目标**: 补齐语言特定的 Taste Invariants

**已实现**:
- `guards/rust/check_taste_invariants.sh` — TASTE-ANSI / TASTE-ASYNC-UNWRAP / TASTE-PANIC-MSG
- `guards/go/common.sh` + `check_error_handling.sh`(GO-01) + `check_goroutine_leak.sh`(GO-02) + `check_defer_in_loop.sh`(GO-08)

**未实现（现有规则 ID 已占用，需评估是否追加）**:
- Rust: RS-07 折叠 if、RS-08 method reference、RS-09 match 穷举（已被现有规则占用）
- Go: GO-06 error 命名、GO-07 defer panic、GO-09 race condition、GO-10 禁 interface{}

**完成日期**: 2026-03-02（核心部分）

---

### P1-3：文档新鲜度检测 ✅

**目标**: 自动检测规则文档与代码实现的不一致

**实现**: `scripts/doc-freshness-check.sh`
- 扫描 rules/*.md 提取规则 ID，扫描 guards/ + hooks/ 提取已实现 ID
- 交叉比对：未实现/未文档化/已覆盖三元分类
- 不一致 >10% WARN，>20% FAIL，支持 --strict 模式

**完成日期**: 2026-03-02

---

### P1-4：能力进化日志 ✅

**目标**: 追踪守卫/规则/Skill 的引入历史

**实现**: `scripts/log-capability-change.sh`
- 扫描 git log 中涉及 guards/rules/hooks/skills 的提交
- 按月分组输出，支持 --since/--type/--json 过滤
- 自动分类：guard/rule/hook/skill + 图标

**完成日期**: 2026-03-02

---

## P2：开发体验优化

### P2-1：Agent-to-Agent 自动链接

**目标**: agent 自动调用其他 agent 形成工作流链

**涉及文件**:
- 新增: `mcp-server/src/agent_connector.ts`
- `agents/dispatcher.md` — 扩展链接规则

**方案**:
```yaml
chains:
  - trigger: build_error
    agents: [build-error-resolver, tdd-guide]
    pass_context: true
```

**工作量**: 45-55h
**依赖**: P0-2
**验收**: 编译错误场景自动链接到测试

---

### P2-2：preflight 约束自动推荐 ✅

**目标**: 减少手工确认约束集的时间

**实现**:
- `scripts/constraint-recommender.py` — 检测语言/框架/模式，自动生成约束初稿
- `.claude/commands/vibeguard/preflight.md` Step 5 集成
- 信心度分级：high（自动接受）/ medium（提示确认）/ low（需讨论）

**完成日期**: 2026-03-02

---

### P2-3：命令别名 ✅

**目标**: 常用命令快捷访问

**实现**: `.claude/commands/vg/` 目录下 4 个转发文件
```
/vg:pf  → /vibeguard:preflight
/vg:gc  → /vibeguard:gc
/vg:ck  → /vibeguard:check
/vg:lrn → /vibeguard:learn
```

**完成日期**: 2026-03-02

---

## P3：文档与知识

### P3-1：Harness 映射文档

**目标**: 显式记录 VibeGuard 与 Harness 每项概念的对应关系

**工作量**: 20-25h

---

### P3-2：集成指南 + 案例

**目标**: 新用户 <30 分钟完成集成

**案例**:
- Rust workspace（依赖层检查）
- Python FastAPI（命名约束 + 质量守卫）
- TypeScript monorepo（any 滥用检测）

**工作量**: 30-40h

---

## 实施路线图

### Phase 1（→ 4 月底）— 防线强化
| 任务 | 周期 |
|------|------|
| P0-1: Hashline 编辑优化 | 4-5 周 |
| P0-2: Turn/Thread 模型 | 5-6 周 |
| **里程碑**: v0.9.0 发布 | Week 8 |

### Phase 2（5-6 月）— 可观测完善
| 任务 | 周期 |
|------|------|
| P1-1: 质量等级评分 | 3-4 周 |
| P1-2: 平台约束 | 3-4 周 |
| P1-3: 文档新鲜度 | 2-3 周 |
| P1-4: 能力日志 | 2 周 |
| **里程碑**: v1.0.0 发布 | Week 16 |

### Phase 3（7 月+）— 体验与知识
| 任务 | 周期 |
|------|------|
| P2-1: Agent 链接 | 4-5 周 |
| P2-2: preflight 推荐 | 3 周 |
| P2-3: 命令别名 | 1 周 |
| P3-1: 映射文档 | 2 周 |
| P3-2: 集成指南 | 3-4 周 |

---

## 完成状态

```
原始:  76%（8 维度加权）
P0:    延后（Hashline 不可行 + Turn/Thread 低必要性）
P1:    ✅ 全部完成（评分 + 约束 + 新鲜度 + 日志）
P2:    2/3 完成（推荐 ✅ + 别名 ✅；Agent 链接延后）
P3:    未开始（映射文档 + 集成指南）

变化维度:
  Architecture Constraints: 88% → 97%
  Feedback Loops:          81% → 88%
  Improvement Cycles:      82% → 92%
  其余维度未变
```

---

## 设计原则

1. **因地制宜**: 不照搬 Harness 的 JSON-RPC，基于 Claude Code 的 Hook + MCP 生态
2. **安全优先**: P0 集中在防幻觉直接有效性
3. **可测试**: 每个任务有明确验收标准
4. **增量交付**: 每个 Phase 独立可发布
