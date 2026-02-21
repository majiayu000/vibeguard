---
name: "VibeGuard: Build Fix"
description: "构建修复 — 读取构建错误，定位根因，执行最小修复，验证构建通过"
category: VibeGuard
tags: [vibeguard, build, fix, error]
argument-hint: "<构建命令或错误信息>"
---

<!-- VIBEGUARD:BUILD-FIX:START -->
**核心理念**
- 构建错误修复的目标是让构建通过，不是重构代码
- 从根因修复，一个修复可能解决多个错误
- 最小改动原则：只修复构建错误，不做额外改进

**Steps**

1. **捕获构建错误**
   - 如果用户提供了错误信息：直接解析
   - 如果用户提供了构建命令：运行命令捕获输出
   - 如果无参数：尝试检测项目类型并运行对应构建命令
     - Rust: `cargo build 2>&1`
     - TypeScript: `npx tsc --noEmit 2>&1`
     - Go: `go build ./... 2>&1`
     - Python: `python -m py_compile <files> 2>&1`

2. **解析错误**
   - 提取：文件路径、行号、错误类型、错误消息
   - 按文件分组
   - 识别错误间的依赖关系（A 导致 B）

3. **定位根因**
   - 读取错误涉及的源文件
   - 区分直接原因和根本原因
   - 多个错误可能源自同一根因 → 优先修复根因

4. **执行最小修复**
   - 只修复构建错误，不做额外改进（L5）
   - 不用 `@ts-ignore` / `# type: ignore` / `//nolint` 绕过
   - 不用 `any` / `as any` 绕过类型错误
   - 不引入新依赖解决标准库能解决的问题（U-06）

5. **验证**
   - 重新运行构建命令，确认零错误
   - 运行测试确认不回归
   - 运行类型检查确认通过

6. **输出修复报告**

   ```markdown
   ## 构建修复报告

   ### 错误摘要
   - 总错误数：N
   - 根因数：M
   - 修复文件数：K

   ### 修复详情
   | 文件:行号 | 错误 | 修复 |
   |-----------|------|------|
   | ...       | ...  | ...  |

   ### 验证
   - 构建：通过/失败
   - 测试：通过/失败
   ```

**Guardrails**
- 不在修复中改变代码风格（U-07）
- 不一次性修复不相关的问题（U-09）
- 修复后必须验证构建通过

**Reference**
- 通用规则：`vibeguard/rules/universal.md`
- 语言规则：`vibeguard/rules/<lang>.md`
<!-- VIBEGUARD:BUILD-FIX:END -->
