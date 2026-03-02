# Claude Code 已知问题与 VibeGuard 应对

> 影响 VibeGuard 规则/hooks/skills 加载的 Claude Code 平台级 bug。
> 最后更新：2026-03-02

## 规则系统 (Rules)

### 1. 用户级 paths 前置条件解析失败

| 字段 | 值 |
|------|------|
| Issue | [#21858](https://github.com/anthropics/claude-code/issues/21858) |
| 状态 | OPEN（未修复） |
| 影响 | `~/.claude/rules/` 下使用 YAML 数组格式 `paths:` 的规则不加载 |
| 根因 | `yaml.parse()` 返回 JS Array，CSV 解析器逐元素迭代而非逐字符，产生无效 glob |

**触发条件**：

```yaml
# ❌ 不生效 — YAML 数组格式
---
paths:
  - "**/*.ts"
  - "**/*.tsx"
---

# ❌ 不生效 — 带引号
---
paths: "**/*.ts"
---
```

**VibeGuard 应对**：

```yaml
# ✅ CSV 单行，不加引号
---
paths: **/*.ts,**/*.tsx,**/*.js,**/*.jsx
---
```

已在 `rules/claude-rules/` 的 4 个语言规则文件中应用此 workaround。

---

### 2. 项目级 paths 规则全局加载

| 字段 | 值 |
|------|------|
| Issue | [#16299](https://github.com/anthropics/claude-code/issues/16299) |
| 状态 | OPEN（未修复） |
| 影响 | `.claude/rules/` 下带 `paths:` 的规则在会话启动时全部加载，不管是否匹配 |
| 后果 | 上下文膨胀 — 28 条规则可能全部加载而不是只加载 5 条 |

**VibeGuard 影响**：低。VibeGuard 用 `~/.claude/rules/`（用户级），且 common/ 下 3 个文件本就无 paths（全局生效）。语言规则用 CSV workaround 可正常作用域过滤。

---

### 3. YAML 前置条件语法无效

| 字段 | 值 |
|------|------|
| Issue | [#13905](https://github.com/anthropics/claude-code/issues/13905) |
| 状态 | OPEN |
| 影响 | 官方文档示例的 YAML 语法在 YAML 规范中无效（`*` 是保留字符不能裸用） |

**VibeGuard 应对**：同 #1，使用 CSV 格式绕过。

---

### 4. Git Worktree 中 paths 被忽略

| 字段 | 值 |
|------|------|
| Issue | [#23569](https://github.com/anthropics/claude-code/issues/23569) |
| 状态 | CLOSED（NOT PLANNED，归入 #16299） |
| 影响 | worktree 解析路径的规则不走 paths 过滤 |

**VibeGuard 影响**：低。VibeGuard 的 `worktree-guard.sh` 是 git 层面的隔离工具，不依赖 Claude Code 的规则加载机制。

---

## Skills 系统

### 5. SKILL.md 验证器拒绝扩展字段

| 字段 | 值 |
|------|------|
| Issue | [#25380](https://github.com/anthropics/claude-code/issues/25380) |
| 状态 | CLOSED（duplicate of #23330，未修复） |
| 影响 | VS Code 扩展的验证器只认 Agent Skills 标准字段，拒绝 `hooks`、`allowed-tools`、`context` 等 Claude Code 扩展字段 |

**VibeGuard 影响**：仅影响 VS Code 中的警告显示。VibeGuard 的 SKILL.md 使用 `name`、`description`、`tags` 等标准字段，不受影响。在 VS Code 中看到黄色警告可忽略。

---

### 6. 插件中 Skill-Scoped Hooks 不触发

| 字段 | 值 |
|------|------|
| Issue | [#17688](https://github.com/anthropics/claude-code/issues/17688) |
| 状态 | OPEN（未修复） |
| 影响 | 通过 `--plugin-dir` 或 marketplace 安装的插件，其 SKILL.md frontmatter 中的 hooks 不执行 |
| 正常工作 | `.claude/skills/` 和 `.claude/agents/` 中的 hooks 正常 |

**VibeGuard 影响**：无。VibeGuard hooks 通过 `settings.json` 注册（`hooks.PreToolUse`/`PostToolUse`），不使用 SKILL.md frontmatter hooks。若未来 VibeGuard 作为插件分发，此 bug 需关注。

---

## 总结：VibeGuard 受影响程度

| 问题 | 严重度 | 已应对 |
|------|--------|--------|
| #21858 用户级 paths YAML 解析 | **高** | ✅ CSV 格式 workaround |
| #16299 项目级 paths 全局加载 | 低 | — 不影响用户级 |
| #13905 YAML 语法无效 | 中 | ✅ CSV 格式 workaround |
| #23569 Worktree paths 忽略 | 低 | — 不依赖此机制 |
| #25380 SKILL.md 验证器 | 低 | — 仅 VS Code 警告 |
| #17688 插件 hooks 不触发 | 无 | — 不使用此机制 |

## 监控建议

定期检查以下 issue 的修复状态：
- **#21858** — 修复后可改回 YAML 数组格式（更易读）
- **#16299** — 修复后项目级规则的上下文开销会降低
- **#17688** — 若 VibeGuard 计划做插件分发需关注
