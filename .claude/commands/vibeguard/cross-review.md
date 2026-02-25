---
name: "VibeGuard: Cross Review"
description: "双模型对抗审查 — Claude 生成审查报告，Codex 做对抗性验证，迭代至收敛"
category: VibeGuard
tags: [vibeguard, review, cross-review, adversarial, codex]
argument-hint: "<项目目录或文件路径>"
---

<!-- VIBEGUARD:CROSS-REVIEW:START -->
**核心理念**
- 单模型审查存在盲区，第二模型独立验证可以发现遗漏
- Claude 负责生成结构化审查，Codex 做对抗性质疑
- 迭代至收敛：最多 3 轮修订，确保审查质量
- Codex 不可用时自动降级为单模型审查（`/vibeguard:review`）

**Steps**

1. **检查 Codex 可用性**
   - 运行 `which codex` 检查 Codex CLI 是否安装
   - 如果不可用，输出提示并降级执行 `/vibeguard:review` 的完整流程，结束
   - 如果可用，继续双模型流程

2. **获取守卫基线**
   - 运行 `mcp__vibeguard__guard_check` 获取当前守卫状态
   - 记录已有问题作为基线（不重复报告）

3. **确定审查范围**
   - 如果指定了文件路径：审查该文件
   - 如果指定了目录：审查最近修改的文件（`git diff --name-only`）
   - 如果无参数：审查当前 git 暂存区的文件
   - 将目标目录记为 `$TARGET_DIR`

4. **Claude 生成审查报告（Round 1）**
   - 按 P0-P3 优先级审查（与 `/vibeguard:review` 一致）：
     - P0 安全：参考 `vibeguard/rules/security.md`，OWASP Top 10、密钥泄露、输入验证
     - P1 逻辑：边界条件、错误处理、并发安全、数据一致性（U-11~U-14）
     - P2 质量：重复代码、命名规范、异常处理、文件大小
     - P3 性能：热路径、N+1 查询、内存分配
   - 将审查报告写入 `/tmp/vibeguard-cross-review-<timestamp>.md`
   - 报告格式：
     ```markdown
     ## Claude 审查报告（Round N）

     ### 守卫基线
     <guard_check 结果摘要>

     ### 发现
     | 优先级 | 文件:行号 | 问题 | 建议 |
     |--------|-----------|------|------|
     | P0     | ...       | ...  | ...  |

     ### 通过项
     - <确认无问题的方面>
     ```

5. **Codex 对抗审查**
   - 运行以下命令（read-only sandbox，不修改任何文件）：
     ```bash
     codex exec --skip-git-repo-check -a read-only -C "$TARGET_DIR" \
       "你是一个对抗性代码审查员。阅读以下审查报告，然后独立检查代码。
        你的任务：
        1. 验证报告中每个发现是否准确（标记 CONFIRMED / FALSE-POSITIVE）
        2. 检查报告是否遗漏了重要问题（列出 MISSED 项）
        3. 评估修复建议是否合理

        审查报告内容：
        $(cat /tmp/vibeguard-cross-review-<timestamp>.md)

        最后输出 VERDICT 行（必须是以下之一）：
        VERDICT: APPROVED — 报告准确完整，无重大遗漏
        VERDICT: REVISE — 需要修订，原因：<具体原因>" 2>/dev/null
     ```
   - 捕获 Codex 输出

6. **解析 Codex VERDICT**
   - 提取 `VERDICT:` 行
   - 如果是 `APPROVED`：跳到步骤 8
   - 如果是 `REVISE`：继续步骤 7
   - 如果无法解析（Codex 输出异常）：视为 APPROVED，在报告中标注"Codex 验证异常，结果仅供参考"

7. **迭代修订（最多 3 轮）**
   - Claude 根据 Codex 反馈修订审查报告：
     - 移除 FALSE-POSITIVE 标记的项
     - 补充 MISSED 遗漏项
     - 调整修复建议
   - 更新 `/tmp/vibeguard-cross-review-<timestamp>.md`
   - 再次调用 Codex 验证（同步骤 5）
   - 如果达到 3 轮仍未 APPROVED：标记为"未收敛"，输出最终报告

8. **输出最终报告**

   ```markdown
   ## 双模型对抗审查报告

   ### 验证状态
   - 模式：Claude + Codex 对抗审查
   - 结果：<APPROVED / 未收敛>
   - 迭代轮数：<N>

   ### 守卫基线
   <guard_check 结果摘要>

   ### 确认的发现
   | 优先级 | 文件:行号 | 问题 | 建议 | 验证 |
   |--------|-----------|------|------|------|
   | P0     | ...       | ...  | ...  | CONFIRMED |

   ### Codex 补充发现
   | 优先级 | 文件:行号 | 问题 | 建议 |
   |--------|-----------|------|------|
   | ...    | ...       | ...  | ...  |

   ### 排除的误报
   | 原发现 | 排除原因 |
   |--------|----------|
   | ...    | FALSE-POSITIVE: ... |

   ### 迭代历史
   | 轮次 | Codex 判定 | 修订内容 |
   |------|-----------|----------|
   | 1    | REVISE    | +2 MISSED, -1 FALSE-POSITIVE |
   | 2    | APPROVED  | — |

   ### 通过项
   - <双方确认无问题的方面>

   ### 建议
   - <改进建议（非必须）>
   ```

9. **清理临时文件**
   - 删除 `/tmp/vibeguard-cross-review-<timestamp>.md`

10. **记录事件**
    - 写入 `~/.vibeguard/events.jsonl`：
      ```bash
      echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"hook\":\"cross-review\",\"tool\":\"command\",\"decision\":\"complete\",\"reason\":\"cross-review finished\",\"detail\":\"rounds=<N>, verdict=<APPROVED/未收敛>, findings=<count>\"}" >> ~/.vibeguard/events.jsonl
      ```

**Guardrails**
- Codex 必须以 read-only 模式运行，不允许修改代码
- 不建议添加不必要的抽象（L5）
- 不建议添加向后兼容层（L7）
- 发现重复代码时，建议扩展已有实现而非新建（L1）
- 审查报告中不包含 AI 生成标记
- Codex 超时或异常时降级为单模型结果，不阻断流程

**Reference**
- 安全规则：`vibeguard/rules/security.md`
- 通用规则：`vibeguard/rules/universal.md`
- 语言规则：`vibeguard/rules/<lang>.md`
- 单模型审查：`.claude/commands/vibeguard/review.md`
<!-- VIBEGUARD:CROSS-REVIEW:END -->
