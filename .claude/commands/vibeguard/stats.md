---
name: "VibeGuard: Stats"
description: "查看 hooks 触发统计 — 拦截/警告/放行次数和原因分析"
category: VibeGuard
tags: [vibeguard, stats, logging, observability]
argument-hint: "[days|all]"
---

**核心功能**
- 分析 `~/.vibeguard/events.jsonl` 中的 hook 触发日志
- 输出拦截/警告/放行统计、按 hook 分布、原因 Top 5、每日触发量
- 帮助用户了解 VibeGuard 是否在工作、拦截了什么

**Steps**

1. 运行统计脚本：
   ```bash
   bash ~/Desktop/code/AI/tools/vibeguard/scripts/stats.sh $ARGUMENTS
   ```
   参数说明：
   - 无参数：最近 7 天
   - 数字（如 30）：最近 N 天
   - `all`：全部历史

2. 将统计结果展示给用户，如有异常（如拦截为 0 但使用了一段时间）提醒检查 hooks 配置是否正确
