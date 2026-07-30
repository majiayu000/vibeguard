# Product Spec — 托管 skill 的持久化退出契约

## Linked Issue

GH-719

complexity: small

## 用户问题

VibeGuard 把 Codex workflow skills（`plan-flow`、`fixflow`、`optflow`、
`plan-mode`、`auto-optimize`）作为默认安装的托管副本。用户从
`~/.codex/skills/` 删掉某个 skill 后，下一次 VibeGuard 安装或更新会静默地把它
整个复制回来——Codex 安装器的实现是「删除目标目录后重新拷贝源树」，因此删除运行
时副本这一动作根本无法表达一个持久的退出意图。

结果是：一次与 skill 无关的 VibeGuard 更新，会重新扩张用户的 Codex skill 目录，
而且全程没有任何提示。用户的显式删除被无声地推翻。

## 目标

- 让用户能够持久地禁用单个托管 skill，且该决定在后续安装/更新中继续生效。
- 重新运行默认/core 安装器不得恢复已禁用的 skill。
- `setup.sh --check` 必须把「有意禁用」与「缺失/损坏」区分开。
- 重新启用必须是显式动作。
- 安装器在恢复一个用户曾删除的托管 skill 时，必须报告该冲突并指出持久退出的方式，
  不得静默恢复。

## 非目标

- 不改变 `workflows` 模块在 manifest 中的默认安装状态；本 issue 提供的是退出机制
  （issue 列出的方案二），而不是把 workflow skills 改成 opt-in（方案一）。
- 不引入新的 CLI 子命令来管理禁用列表；用户配置文件即是唯一来源。
- 不改变非托管的、用户自有的 skill 目录的任何行为。

## 用户可见行为

用户在 `~/.vibeguard/config.json` 中记录退出意图：

```json
{
  "version": 1,
  "disabled_skills": ["plan-flow", "fixflow"]
}
```

| 场景 | 行为 |
|---|---|
| skill 在禁用列表中，且已安装 | 安装时删除托管副本并输出 `REMOVED <skill> (disabled ...)` |
| skill 在禁用列表中，且不存在 | 安装时输出 `SKIP <skill> (disabled ...)`，不安装 |
| skill 被用户手工删除，但未记录退出 | 恢复它，同时输出 `RESTORING <skill>` 并指明如何持久禁用 |
| `--check`，skill 已禁用且不存在 | `[DISABLED] <skill> skill disabled in ~/.vibeguard/config.json` |
| `--check`，skill 已禁用但仍存在 | 同上并追加提示重跑 `setup.sh` 以移除 |
| 从列表中移除名字后重跑安装 | skill 重新安装 |
| `disabled_skills` 格式非法 | 安装与 `--check` 失败并报出带 JSON 路径的类型错误 |

`VIBEGUARD_DISABLED_SKILLS`（逗号分隔）可临时覆盖该列表，遵循用户配置既有的
「环境变量 > JSON 配置 > 内置默认」优先级。

## 完成条件

- 用户可以持久禁用单个 Codex workflow skill。
- 默认安装器重跑不恢复被禁用的 skill。
- `--check` 对被禁用 skill 报 `[DISABLED]` 而非 `[MISSING]`。
- 重新启用是显式的。
- 存在覆盖「删除/禁用 → 重装 → 仍保持禁用」的 setup 回归测试。
- 托管 Codex skill 副本的行为与来源归属有文档说明。
