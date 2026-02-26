# scripts/ 目录

VibeGuard 工具脚本，提供统计、合规检查、指标收集等功能。

## 脚本说明

| 脚本 | 用途 |
|------|------|
| `stats.sh` | 分析 events.jsonl，输出 hook 触发统计、warn 遵守率、文件类型和时段分布 |
| `compliance_check.sh` | 项目合规性检查，验证代码规范遵守情况 |
| `metrics_collector.sh` | 收集项目代码指标（行数、复杂度等） |
| `worktree-guard.sh` | 大改动隔离辅助：创建/列出/合并/删除 git worktree |
| `blueprint-runner.sh` | 蓝图编排器：读取 blueprints/*.json，按顺序执行确定性/代理节点 |

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
```
