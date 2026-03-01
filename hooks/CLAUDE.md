# hooks/ 目录

Claude Code hooks 脚本，在 AI 操作前后自动触发。

## 文件说明

| 文件 | 触发时机 | 职责 |
|------|----------|------|
| `log.sh` | 被其他 hook source | 日志模块，提供 `vg_log`、JSON 解析、源码判断等共享函数 |
| `pre-bash-guard.sh` | PreToolUse(Bash) | 拦截危险命令：force push、rm -rf /、reset --hard 等 |
| `pre-edit-guard.sh` | PreToolUse(Edit) | 拦截编辑不存在的文件（防幻觉） |
| `pre-write-guard.sh` | PreToolUse(Write) | 新建源码文件前提醒先搜索已有实现 |
| `post-edit-guard.sh` | PostToolUse(Edit) | 编辑后检测质量问题：unwrap、console.log、硬编码路径 |
| `post-write-guard.sh` | PostToolUse(Write) | 新文件创建后检测重复定义和同名文件 |
| `post-build-check.sh` | PostToolUse(Edit/Write) | 编辑后自动运行语言对应的构建检查 |
| `post-guard-check.sh` | PostToolUse(guard_check) | MCP guard_check 调用后的处理 |
| `skills-loader.sh` | PreToolUse(Read) | 会话首次工具调用时自动加载匹配的 Skill（每会话一次） |
| `stop-guard.sh` | Stop | 完成前验证门禁，检查未提交的源码变更 |
| `learn-evaluator.sh` | Stop | 会话结束时深度分析事件日志，发现可提取信号时门禁暂停（exit 2） |
| `pre-commit-guard.sh` | git pre-commit | 提交前自动守卫：质量检查 + 构建检查，10s 超时硬限 |

## Decision 类型

hooks 使用以下 decision 类型记录到 events.jsonl：
`pass` / `warn` / `block` / `gate` / `escalate` / `complete`

## 开发规范

- 所有 hook 必须 `source log.sh` 引入共享函数
- 使用 `vg_log` 记录事件，不直接写文件
- 通过环境变量传递数据给 python3，避免注入风险
