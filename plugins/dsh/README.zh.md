# VibeGuard for DeepSeek Harness

`@vibeguard/dsh` 是一个原生 DSH 守卫插件，直接复用已安装 VibeGuard 的标准 hook 脚本。所有能对应 DSH 生命周期的 VibeGuard hook 都已接入：

| DSH 生命周期 | VibeGuard hooks |
|---|---|
| `agent/session-start` + 首次 `agent/pre-step` 门控 | `count-active-constraints` |
| Bash/Edit/Write 的 `tools/pre-execute` | `pre-bash-guard`、`pre-edit-guard`、`pre-write-guard` |
| Edit/Write/Bash 的 `tools/post-execute` | `post-edit-guard`、`post-write-guard`、`post-build-check` |
| Read/Glob/Grep 的 `tools/post-execute` | `analysis-paralysis-guard` |
| `agent/turn-stopping` | `stop-guard`、`learn-evaluator` |

DSH 的 `str_replace_editor` 会先规范化为 Read、Edit 或 Write 再路由。成功修改文件后，独立的完成守卫会检查本回合是否有验证命令成功；Stop hook 与完成守卫每回合最多让智能体继续一次，避免反馈循环。

所有决定都使用同一份结构化 JSON：

```json
{
  "version": "vibeguard.dsh/v1",
  "decision": "deny",
  "signals": [
    {
      "signal_type": "command_policy",
      "signal": "vibeguard_pre_bash_deny",
      "reason": "..."
    }
  ]
}
```

## 环境要求

- Node.js `^22.19` 或 `>=24`
- DeepSeek Harness `0.1.0-rc.5` 或兼容的新版本
- 已通过 `./setup.sh` 安装 VibeGuard；插件默认调用 `~/.vibeguard/installed/hooks` 下的脚本

## 本地构建与安装

```bash
cd plugins/dsh
corepack pnpm install
corepack pnpm test
corepack pnpm build
corepack pnpm pack --pack-destination dist

dsh plugin --profile demo add ./dist/vibeguard-dsh-0.1.0.tgz
dsh --profile demo --dump-config
```

该 bundle 会插入一个名为 `vibeguard` 的 Cordis 配置行，可用于所有包含 DSH base bundle 的 profile。

## 配置

在 profile 的 `cordis.patch.yml` 中覆盖该配置行：

```yaml
- id: vibeguard
  config:
    hooksDir: ''
    failureMode: closed
    timeoutMs: 5000
    buildTimeoutMs: 35000
    stdoutMaxBytes: 65536
    enabledHooks:
      - count-active-constraints
      - pre-bash-guard
      - pre-edit-guard
      - pre-write-guard
      - post-edit-guard
      - post-write-guard
      - post-build-check
      - analysis-paralysis-guard
      - stop-guard
      - learn-evaluator
    guardUnverifiedCompletion: true
    mutatingTools: [write, edit, str_replace_editor]
    verificationCommandPatterns:
      - '(^|[;&|]\\s*)pnpm\\s+(test|lint|check|build)(\\s|$)'
```

`hooksDir: ''` 表示使用已安装快照。`failureMode: closed` 会在任一启用 hook 运行失败、超时、被中止、输出被截断或返回非法结构化结果时明确失败。只有在可用性比守卫执行更重要时，才建议改为 `open`。

## v0.1 有意保留的边界

本版本不做 Web UI、注册中心、npm 发布流程或依赖供应链扫描。完成守卫只跟踪 DSH 文件编辑工具产生的修改；暂不判断 Bash 命令是否修改了文件。

[English](README.md)
