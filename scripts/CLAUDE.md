# scripts/ 目录

VibeGuard 工具脚本，提供统计、合规检查、指标收集等功能。

## 脚本说明

| 脚本 | 用途 |
|------|------|
| `stats.sh` | 分析 events.jsonl，输出 hook 触发统计、warn 遵守率、文件类型和时段分布 |
| `verify/compliance_check.sh` | 项目合规性检查，验证代码规范遵守情况 |
| `metrics/metrics_collector.sh` | 收集项目代码指标（行数、复杂度等） |
| `worktree-guard.sh` | 大改动隔离辅助：创建/列出/合并/删除 git worktree |
| `blueprint-runner.sh` | 蓝图编排器：读取 blueprints/*.json，按顺序执行确定性/代理节点 |
| `gc/gc-logs.sh` | 日志归档：events.jsonl 超过 10MB 时按月归档压缩，保留 3 个月 |
| `gc/gc-worktrees.sh` | Worktree 清理：删除不活跃 >7 天的 worktree，未合并变更只警告 |
| `metrics/metrics-exporter.sh` | Prometheus 指标导出：从 events.jsonl 聚合生成 4 类指标 |
| `gc/gc-scheduled.sh` | 定期 GC + 学习 + 反思：日志归档、worktree 清理、metrics 清理、跨会话学习信号检测、会话质量反思报告 |
| `project-init.sh` | 项目级脚手架：检测语言/框架 → 列出激活守卫/规则 → 生成 CLAUDE.md 片段建议，并安装 pre-commit/pre-push hook |
| `quality-grader.sh` | 质量等级评分：从 events.jsonl 计算 A/B/C/D 等级，推荐 GC 频率 |
| `hook-health.sh` | Hook 健康快照：最近 N 小时风险率、Top 风险 hook、最近风险事件 Top 10 |
| `verify/doc-freshness-check.sh` | 文档新鲜度：交叉比对 rules/ 和 guards/ 的规则 ID 覆盖度 |
| `log-capability-change.sh` | 能力进化日志：从 git log 提取守卫/规则/Skill 变更时间线 |
| `constraint-recommender.py` | 约束推荐器：基于项目语言/框架自动生成 preflight 约束初稿 |

## CI 脚本 (scripts/ci/)

| 脚本 | 用途 |
|------|------|
| `validate-guards.sh` | 验证所有守卫脚本可执行且格式正确 |
| `validate-hooks.sh` | 验证所有 hook 脚本可执行且格式正确 |
| `validate-rules.sh` | 验证规则文件格式和 ID 唯一性 |

## 用法

```bash
bash scripts/stats.sh          # 最近 7 天统计
bash scripts/stats.sh 30       # 最近 30 天
bash scripts/stats.sh all      # 全部历史
bash scripts/hook-health.sh 24 # 最近 24 小时健康快照
```
