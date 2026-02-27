---
name: vibeguard
description: "AI 辅助开发防幻觉规范。查阅七层防御架构、量化指标、执行模板和实战案例。用于代码审查、任务启动检查、周度复盘。"
---

# VibeGuard — 防幻觉规范 Skill

## Overview

VibeGuard 是 AI 辅助开发的防幻觉框架，通过七层防御架构系统性地阻止 LLM 代码生成中的常见失效模式。

调用 `/vibeguard` 可以：
- 查阅完整防幻觉规范
- 获取任务启动 checklist
- 查看评分矩阵进行风险评估
- 获取周度复盘模板

## 触发条件

当用户提到以下内容时触发：
- "检查防幻觉规范"、"vibeguard"
- "任务启动检查"、"task contract"
- "周度复盘"、"review template"
- "风险评估"、"risk scoring"
- "代码质量守卫"、"guard rules"

## 七层防御架构速查

| 层级 | 名称 | 关键工具/规则 |
|------|------|---------------|
| L1 | 反重复系统 | `check_duplicates.py` / 先搜后写 |
| L2 | 命名约束 | `check_naming_convention.py` / snake_case |
| L3 | Pre-commit Hooks | ruff / gitleaks / shellcheck |
| L4 | 架构守卫测试 | `test_code_quality_guards.py` 五条规则 |
| L5 | Skill/Workflow | plan-flow / fixflow / optflow |
| L6 | Prompt 内嵌规则 | CLAUDE.md 强制规则 |
| L7 | 周度复盘 | review-template.md |

## 快速使用

### 任务启动检查

```
参考 references/task-contract.yaml，确认：
1. 目标明确且可验证
2. 数据来源已确定
3. 验收标准可测试
```

### 风险评估

```
参考 references/scoring-matrix.md，对每个发现评分：
- impact（影响）: 1-5
- effort（工作量）: 1-5
- risk（风险）: 1-5
- confidence（置信度）: 1-5
公式: priority = (impact × confidence) - (effort + risk)
```

### 周度复盘

```
参考 references/review-template.md，记录：
1. 本周回归事件
2. 守卫拦截统计
3. 指标趋势
4. 下周重点
```

## 参考文档

- `references/task-contract.yaml` — 任务启动 Checklist（机器校验格式）
- `references/review-template.md` — 周度复盘模板
- `references/scoring-matrix.md` — risk-impact 评分矩阵
- `spec.md`（仓库根目录）— 完整规范文档

## 执行规则

- 每次开发任务启动前，过一遍 task contract
- 每周五进行一次复盘，使用 review template
- 发现回归时，先定位失效防线，再补强规则
- 新规则必须有对应的自动检测手段（守卫/hook/测试）
