---
name: "VibeGuard: Check"
description: "一键运行所有守卫脚本，输出项目健康度报告"
category: VibeGuard
tags: [vibeguard, check, guard, quality]
argument-hint: "[project_dir]"
---

<!-- VIBEGUARD:CHECK:START -->
**核心理念**
- 快速、无侵入地检查当前项目的代码健康度
- 自动检测项目语言，运行对应的守卫脚本
- 输出结构化报告，按严重度排序
- 可在编码过程中随时运行，验证修改未引入新问题

**Guardrails**
- 只读操作，不修改任何文件
- 不自动修复 — 只报告问题，修复由用户决定
- 如果用户提供了 preflight 约束集基线，对比基线报告变化

**Steps**

1. **确定项目路径和语言**
   - 项目路径：用户参数 > 当前工作目录
   - 语言检测：
     - `Cargo.toml` → Rust
     - `package.json` → TypeScript/JavaScript
     - `pyproject.toml` / `setup.py` / `requirements.txt` → Python
     - `go.mod` → Go
   - 定位 vibeguard 安装路径（`~/Desktop/code/AI/tools/vibeguard/` 或通过 `VIBEGUARD_DIR` 环境变量）

2. **运行语言对应的守卫脚本**

   **Rust 项目**：
   ```bash
   bash ${VIBEGUARD_DIR}/guards/rust/check_unwrap_in_prod.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/rust/check_duplicate_types.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/rust/check_nested_locks.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/rust/check_workspace_consistency.sh <project_dir>
   ```

   **TypeScript/JavaScript 项目**：
   ```bash
   bash ${VIBEGUARD_DIR}/guards/typescript/check_any_abuse.sh <project_dir>
   bash ${VIBEGUARD_DIR}/guards/typescript/check_console_residual.sh <project_dir>
   ```

   **Python 项目**：
   ```bash
   python3 ${VIBEGUARD_DIR}/guards/python/check_duplicates.py <project_dir>
   python3 ${VIBEGUARD_DIR}/guards/python/check_naming_convention.py <project_dir>
   python3 ${VIBEGUARD_DIR}/guards/python/test_code_quality_guards.py
   ```

   每个守卫独立运行，一个失败不影响其他守卫。

3. **运行合规检查**
   ```bash
   bash ${VIBEGUARD_DIR}/scripts/compliance_check.sh <project_dir>
   ```

4. **汇总报告**

   输出格式：
   ```
   ══════════════════════════════════
   VibeGuard Health Report
   项目：<project_name>
   日期：<date>
   ══════════════════════════════════

   ┌─ RS-03 unwrap/expect ─────────┐
   │ 发现：50 处                    │
   │ 严重度：中                     │
   └────────────────────────────────┘

   ┌─ RS-05 重复类型 ──────────────┐
   │ 发现：2 处                     │
   │ 严重度：中                     │
   │ - SearchQuery (server, core)  │
   │ - AppState (desktop, server)  │
   └────────────────────────────────┘

   ┌─ RS-01 嵌套锁 ────────────────┐
   │ 发现：0 处                     │
   │ 严重度：✓ 通过                 │
   └────────────────────────────────┘

   ┌─ RS-06 跨入口一致性 ──────────┐
   │ 发现：2 处                     │
   │ 严重度：中                     │
   └────────────────────────────────┘

   ┌─ 合规检查 ─────────────────────┐
   │ PASS: 3  WARN: 3  FAIL: 2    │
   └────────────────────────────────┘

   综合评分：6.5 / 10
   ```

5. **与 preflight 基线对比（可选）**
   - 如果之前运行过 `/vibeguard:preflight` 并记录了基线
   - 对比当前数据与基线，标记恶化项：
     ```
     ┌─ 基线对比 ──────────────────┐
     │ unwrap:  50 → 48  ✓ (-2)   │
     │ 重复类型: 2 → 2   = (不变)  │
     │ 嵌套锁:  0 → 0   ✓ (不变)  │
     │ 一致性:  2 → 0   ✓ (-2)    │
     └────────────────────────────┘
     ```
   - 如有恶化项，明确警告

**Reference**
- VibeGuard 守卫脚本：`vibeguard/guards/`
- VibeGuard 合规检查：`vibeguard/scripts/compliance_check.sh`
- 配合 `/vibeguard:preflight` 使用效果最佳
<!-- VIBEGUARD:CHECK:END -->
