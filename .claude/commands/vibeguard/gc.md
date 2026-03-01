---
name: "VibeGuard: GC"
description: "垃圾回收 — 日志归档、Worktree 清理、代码垃圾扫描"
category: VibeGuard
tags: [vibeguard, gc, cleanup, maintenance]
---

<!-- VIBEGUARD:GC:START -->
**核心理念**（来自 OpenAI Harness Engineering）
- AI 生成的代码会产生"垃圾"（slop）：空 catch 块、遗留调试代码、过期 TODO、死代码
- 手动清理消耗大量工时（Harness 团队曾每周五花 20% 时间清理）
- 自动化 GC 让清理吞吐量与代码生成吞吐量等比例扩展

**触发条件**
- 定期维护（建议每周一次）
- 日志文件过大时
- 项目代码量增长后

**Guardrails**
- 有未合并变更的 Worktree 只警告不删除
- 日志归档前验证 JSON 格式，损坏行保留在主文件
- 代码垃圾扫描只报告不自动修复（修复需用户确认）

**Steps**

1. **日志归档**
   - 运行 `bash ${VIBEGUARD_DIR}/scripts/gc-logs.sh`
   - events.jsonl 超过 10MB 时按月归档（gzip）
   - 保留最近 3 个月，更老的自动删除
   - 输出归档统计

2. **Worktree 清理**
   - 运行 `bash ${VIBEGUARD_DIR}/scripts/gc-worktrees.sh`
   - 删除超过 7 天未活跃且无未合并变更的 worktree
   - 有未合并变更的只警告，列出需要手动处理的

3. **代码垃圾扫描**
   - 运行 `bash ${VIBEGUARD_DIR}/guards/universal/check_code_slop.sh <项目目录>`
   - 检测 5 类 AI 垃圾模式：空异常处理、遗留调试代码、过期 TODO、死代码标记、超长文件
   - 输出结构化报告

4. **汇总报告**
   ```
   VibeGuard GC 报告
   ==================
   日志: 归档 XX 条，当前 XX 条
   Worktree: 清理 X 个，警告 X 个
   代码垃圾: X 个问题
     - 空异常处理: X
     - 遗留调试代码: X
     - 过期 TODO: X
     - 死代码标记: X
     - 超长文件: X
   ```

5. **建议修复**
   - 对每类垃圾问题给出修复建议
   - 用户确认后可逐项修复
   - 修复后运行 `/vibeguard:check` 验证

**Reference**
- 日志归档: `scripts/gc-logs.sh`
- Worktree 清理: `scripts/gc-worktrees.sh`
- 代码垃圾检测: `guards/universal/check_code_slop.sh`
<!-- VIBEGUARD:GC:END -->
