---
name: "VibeGuard: Review"
description: "结构化代码审查 — 先运行守卫获取基线，再按安全→逻辑→质量→性能优先级审查"
category: VibeGuard
tags: [vibeguard, review, code-review, security]
argument-hint: "<项目目录或文件路径>"
---

<!-- VIBEGUARD:REVIEW:START -->
**核心理念**
- 审查不是找茬，是系统性验证代码质量
- 按优先级分层：安全问题 > 逻辑 bug > 代码质量 > 性能
- 每个发现都附带具体修复建议

**Steps**

1. **获取守卫基线**
   - 运行 `mcp__vibeguard__guard_check` 获取当前守卫状态
   - 记录已有问题（不重复报告）

2. **确定审查范围**
   - 如果指定了文件路径：审查该文件
   - 如果指定了目录：审查最近修改的文件（`git diff --name-only`）
   - 如果无参数：审查当前 git 暂存区的文件

3. **P0 — 安全审查**
   - 参考 `vibeguard/rules/security.md`
   - 检查 OWASP Top 10 相关问题
   - 检查密钥/凭证泄露
   - 检查输入验证和消毒

4. **P1 — 逻辑正确性**
   - 边界条件处理
   - 错误处理完整性
   - 并发安全
   - 数据一致性（多入口路径一致 U-11~U-14）

5. **P2 — 代码质量**
   - 重复代码检测（是否有已有实现可复用）
   - 命名规范（参考 L2 命名约束）
   - 异常处理（禁止静默吞异常 L3）
   - 文件大小（> 800 行标记）
   - 参考对应语言规则文件

6. **P3 — 性能**
   - 热路径上的性能问题
   - N+1 查询
   - 不必要的内存分配

7. **输出审查报告**

   ```markdown
   ## 审查报告

   ### 守卫基线
   <guard_check 结果摘要>

   ### 发现
   | 优先级 | 文件:行号 | 问题 | 建议 |
   |--------|-----------|------|------|
   | P0     | ...       | ...  | ...  |

   ### 通过项
   - <确认无问题的方面>

   ### 建议
   - <改进建议（非必须）>
   ```

**Guardrails**
- 不建议添加不必要的抽象（L5）
- 不建议添加向后兼容层（L7）
- 发现重复代码时，建议扩展已有实现而非新建（L1）
- 审查报告中不包含 AI 生成标记

**Reference**
- 安全规则：`vibeguard/rules/security.md`
- 通用规则：`vibeguard/rules/universal.md`
- 语言规则：`vibeguard/rules/<lang>.md`
<!-- VIBEGUARD:REVIEW:END -->
