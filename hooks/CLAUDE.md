# hooks/ 目录

AI 编码代理 hooks 脚本，在操作前后自动触发。同时支持 Claude Code 和 Codex CLI。

## 文件说明

| 文件 | 触发时机 | 职责 | Codex |
|------|----------|------|-------|
| `log.sh` | 被其他 hook source | 日志模块，提供 `vg_log`、JSON 解析、源码判断等共享函数 | — |
| `circuit-breaker.sh` | 被其他 hook source | 断路器库：CLOSED→OPEN→HALF-OPEN 状态机、CI guard、stop_hook_active 检查 | — |
| `run-hook-codex.sh` | Codex wrapper | Codex 输出格式适配器（`decision:block` → `permissionDecision:deny`） | — |
| `pre-bash-guard.sh` | PreToolUse(Bash) | 拦截危险命令：force push、rm -rf /、reset --hard 等 | ✅ |
| `pre-edit-guard.sh` | PreToolUse(Edit) | 拦截编辑不存在的文件（防幻觉） | ❌ |
| `pre-write-guard.sh` | PreToolUse(Write) | 新建源码文件前提醒先搜索已有实现 | ❌ |
| `post-edit-guard.sh` | PostToolUse(Edit) | 编辑后检测质量问题：unwrap、console.log、硬编码路径、Go error 丢弃、超大 diff、同文件反复编辑（churn） | ❌ |
| `post-write-guard.sh` | PostToolUse(Write) | 新文件创建后检测重复定义和同名文件 | ❌ |
| `post-build-check.sh` | PostToolUse(Edit/Write) | 编辑后自动运行语言对应的构建检查 | ✅ |
| `skills-loader.sh` | 手动可选 | 可选的首次 Read 提示脚本；默认不注册到 hooks | ❌ |
| `stop-guard.sh` | Stop | 完成前验证门禁，检查未提交的源码变更 | ✅ |
| `learn-evaluator.sh` | Stop | 会话结束时采集指标 + 检测纠正信号（高 warn 率、文件 churn、escalate），有信号时建议 /learn | ✅ |
| `pre-commit-guard.sh` | git pre-commit | 提交前自动守卫：质量检查 + 构建检查，10s 超时硬限 | — |

**Codex 列说明**：✅ = 已部署到 `~/.codex/hooks.json`，❌ = Codex 暂不支持该 matcher，— = 不适用

## 双平台部署架构

```
Claude Code                          Codex CLI
~/.claude/settings.json              ~/.codex/hooks.json
  ↓                                    ↓
run-hook.sh (wrapper)                run-hook-codex.sh (wrapper + 格式适配)
  ↓                                    ↓
~/.vibeguard/installed/hooks/*       ~/.vibeguard/installed/hooks/* (共享)
```

- Claude Code: hooks 注册在 `settings.json`，通过 `run-hook.sh` 分发
- Codex CLI: hooks 注册在 `hooks.json`，通过 `run-hook-codex.sh` 分发并适配输出格式
- 两者共享同一份 hook 脚本快照（`~/.vibeguard/installed/hooks/`）

## Decision 类型

hooks 使用以下 decision 类型记录到 events.jsonl：
`pass` / `warn` / `block` / `gate` / `escalate` / `correction` / `complete`

## 开发规范

- 所有 hook 必须 `source log.sh` 引入共享函数
- 使用 `vg_log` 记录事件，不直接写文件
- 通过环境变量传递数据给 python3，避免注入风险
- 新增 hook 时同步检查是否可部署到 Codex（看 matcher 支持）
