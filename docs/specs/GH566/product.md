# Product Spec

## Linked Issue

GH-566

## User Problem

Codex 会在每次 Bash 工具调用前执行 `~/.codex/hooks.json` 里的
`PreToolUse` hook。当前 VibeGuard 安装/清理逻辑会保留 unmanaged
第三方 hook，这是正确的安全默认值；但如果一个 unmanaged `PreToolUse`
命令指向不存在的本地文件，Codex 会在真实命令执行前持续显示：

```text
PreToolUse hook (failed)
error: hook exited with code 1
```

这会让用户误以为 SpecRail、构建或仓库命令失败。实际情况可能是业务检查
已经通过，只是坏的全局 `PreToolUse` 残留每次都退出 1。

一个具体风险是测试 fixture 'node /existing/non-vibeguard.js'。它原本用于
验证 VibeGuard 不误删第三方 hook；但如果 fixture 进入真实
`~/.codex/hooks.json`，Node 会因为 `MODULE_NOT_FOUND` 失败，而 VibeGuard
又会把它当作第三方 hook 保留下来。

## Goals

- 让 `setup --check --strict` 能把缺失目标的 unmanaged Codex
  `PreToolUse` hook 报为 repair-required 或 broken，而不是只作为一般
  timeout 警告。
- 提供显式、可审计的修复路径，能移除确认缺失目标的 unmanaged stale hook，
  同时继续保留合法第三方 hook。
- 防止 VibeGuard 测试 fixture 被误认为真实可保留 hook，降低真实 HOME 被
  测试污染后的恢复成本。
- 在 troubleshooting 文档中给出 `PreToolUse hook (failed)` 的定位和修复
  步骤。

## Non-Goals

- 不删除所有 unmanaged hook。
- 不改变 Codex `hooks.json` schema。
- 不默认覆盖用户自定义 hook 命令。
- 不把第三方 hook 统一纳入 VibeGuard 管理范围。
- 不修改 Codex host 的 hook 执行语义。

## Behavior Invariants

1. VibeGuard-managed hook 的识别仍然只基于 `hooks/manifest.json` 和
   namespaced `vibeguard-*.sh` 命令；不得把普通第三方 hook 标成 managed。
2. `setup --check` 默认只检查和报告，不修改 `~/.codex/hooks.json`。
3. 显式修复只删除可证明目标缺失的 stale hook entry，并在输出中列出
   `config`、`event`、`matcher`、`command` 或解析出的 `command_path`。
4. 合法存在的第三方 hook 必须继续被保留，即使命令不带 timeout。
5. 修复路径必须保留 JSON 格式、其他 event、其他 hook entry 和原字段顺序的
   语义，不做无关重写。
6. 测试必须在临时 HOME 中构造 fixture；测试退出后不得把 fixture 命令写入
   真实 `~/.codex/hooks.json`。

## Acceptance Criteria

- [ ] `setup --check --strict` 对缺失目标的 unmanaged Codex
      `PreToolUse(Bash)` entry 返回 broken/repair-required verdict，并显示
      精确 command path 和修复提示。
- [ ] 新增显式修复命令或 setup flag，能删除 stale unmanaged `PreToolUse`
      entry；同一个测试中存在的有效第三方 hook 和 VibeGuard-managed hook
      都被保留。
- [ ] 现有“保留第三方 hook”回归测试改用临时 HOME 下真实存在的第三方脚本，
      不再依赖 '/existing/non-vibeguard.js' 作为可保留 hook。
- [ ] 新增测试覆盖 fixture 泄漏场景：当 'node /existing/non-vibeguard.js'
      出现在 Codex `PreToolUse` 中时，检查命令必须报告为不可用。
- [ ] troubleshooting 文档说明如何区分业务命令失败和 Codex
      `PreToolUse` 残留失败。

## Edge Cases

- 命令通过解释器调用脚本：`node /path/to/hook.js`、`bash /path/to/hook.sh`、
  `python3 /path/to/hook.py`。
- 命令直接调用绝对路径：`/path/to/hook --flag`。
- 命令前有 `env VAR=value` 或简单 shell quoting。
- hook entry 里有多个 hook，修复只能删除 stale hook 本身，不能删除同 entry
  下其他可用 hook。
- 非 `PreToolUse` 的 stale unmanaged hook 仍可先保持 warning，除非后续实现
  证明它同样会阻断关键工作流。

## Rollout Notes

先落诊断和测试 fixture 隔离，再落显式修复路径。修复行为涉及用户高上下文
配置文件，必须保持 opt-in、输出可审计，并在 PR 中展示 before/after fixture
证据。
