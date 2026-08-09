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
- 不把 Codex 的退出意图扩展到 Claude。相同名称的 Claude skill 继续按 Claude manifest
  安装；`disabled_skills` 只控制 `~/.codex/skills/` 下的托管副本。

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
| skill 在禁用列表中，且已安装 | 安装时把精确托管副本原子隔离并输出 `QUARANTINED <skill> at <path> (disabled ...)`；不自动删除隔离数据 |
| skill 在禁用列表中，且不存在 | 安装时输出 `SKIP <skill> (disabled ...)`，不安装 |
| skill 被用户手工删除，但未记录退出 | 恢复它，同时输出 `RESTORING <skill>` 并指明如何持久禁用 |
| `--check`，skill 已禁用且不存在 | `[DISABLED] <skill> skill disabled in ~/.vibeguard/config.json` |
| `--check`，skill 已禁用且仍是 install-state 精确拥有的副本 | `[DISABLED]` 并提示重跑 `setup.sh` 以隔离；保持健康退出 |
| `--check`，skill 已禁用但目录不受 install-state 精确拥有 | `[BROKEN]`；strict/JSON 检查非零，不能承诺 setup 会移除用户内容 |
| 从列表中移除名字后重跑安装 | skill 从 canonical source 重新安装；先前隔离副本继续保留并输出 `RE-ENABLED` |
| `disabled_skills` 格式非法 | 安装与 `--check` 失败并报出带 JSON 路径的类型错误 |

只有 install-state 的 source/type/checksum 与当前目录逐文件一致，且目录没有额外文件、
symlink、特殊文件或空的用户目录时，安装器才可把它认定为托管副本并原子隔离。
ownership 无法证明、state 损坏或隔离失败时必须保留公开目录、非零退出，且不得输出
`QUARANTINED`。`setup.sh --clean` 不自动删除隔离数据；存在 active quarantine 时必须保留
install-state ownership inventory 并明确报告，不能在留下隐藏资产时声称状态已删除。
drift 检查必须在 active quarantine locator 上验证原 tracked bytes，不能把按设计缺失的
public path 报为损坏；中断的 incomplete generation 重试必须保留 locator 与 tracked inventory。
若用户在重试前新增 opt-out，重试还必须保留该 skill 公开根下 type/checksum 仍可验证的
incomplete tracked files，不能因先清空库存而永久失去 ownership 证明。

`VIBEGUARD_DISABLED_SKILLS`（逗号分隔）可临时覆盖该列表，遵循用户配置既有的
「环境变量 > JSON 配置 > 内置默认」优先级。显式空值表示本次临时启用全部 skill；
消息必须区分临时环境变量覆盖与持久配置。名称闭集为
`^[A-Za-z0-9][A-Za-z0-9._-]*$`。

安装器在解析并验证退出列表之前不得替换 installed snapshot、install-state 或任何
Claude/Codex 托管 skill。bootstrap 可以先在 distribution 目录完成已验证 payload 的
staging/current 切换，但 child setup 的上述 active-install mutation 仍受该 preflight
边界约束。preflight 到 install-state 与两个 target mutation 结束之间必须持有同一
HOME-scoped lifecycle lock。锁只能把已经含完整 owner metadata 的目录原子发布到 canonical
路径，并通过原子重命名退役整个目录；进程中断时不得留下 ownerless canonical lock。
current/previous generation 的跨文件排序也必须在 active-install mutation 前的 preflight 拒绝。

## 完成条件

- 用户可以持久禁用单个 Codex workflow skill。
- 默认安装器重跑不恢复被禁用的 skill。
- `--check` 对不存在或仍由 install-state 精确拥有的被禁用 skill 报 `[DISABLED]`；
  对 unowned/modified 同名路径报 `[BROKEN]` 并非零退出，均不误报 `[MISSING]`。
- 重新启用是显式的。
- 存在覆盖「删除/禁用 → 重装 → 仍保持禁用」的 setup 回归测试。
- 托管 Codex skill 副本的行为与来源归属有文档说明。
- 无法证明 ownership、损坏 state、并发 setup 与 quarantine 失败均 fail-visible，且不删除
  用户内容；PID 复用不能把 stale setup lock 误判为当前 owner。
