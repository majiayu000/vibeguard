# VibeGuard 的 DeepSeek Harness 适配

[English](README.md)

`@vibeguard/dsh` 把 DSH 的 Bash 调用前、调用后事件交给本机 VibeGuard Rust 可执行文件。命令策略和结果存储仍由 Rust 负责。

| DSH 边界 | 行为 |
|---|---|
| `tools/pre-execute`，工具 `bash` | 用 stdin 传入 PreToolUse JSON，调用 `vibeguard-runtime hook dsh`。策略拒绝转成原生 `ask`，运行时失败直接 `deny`。 |
| `tools/post-execute`，工具 `bash` | 用 PostToolUse 传入结构化退出码、失败和后台事实。观察失败只提示，保留已完成结果。 |

DSH ToolRuntime 自行请求 ApprovalService 审批并记录 `approval/asked`、`approval/decided`。单次批准允许一次执行；拒绝、取消、审批渠道不可用、缺审批服务或缺 Agent 都拒绝执行。下游其他策略拒绝仍保留，运行时错误不能通过批准绕过。

当前 VibeGuard v2 没有会话开始、Stop、Read、Edit、Write 策略，因此适配不注册这些事件。它不从命令名推断验证完成、不判断任务完成，也不自行执行提议命令。Bash 识别范围见[运行时契约](../../docs/runtime-contract.md)。

## 环境与本地安装

需要 Node.js `^22.19.0` 或 `>=24`，以及 DSH **0.2.0-rc.2**（`next`）。测试使用已发布 npm 包，不承诺其他预发布版本兼容。VibeGuard 必须从本版本构建并支持 `hook dsh`；旧二进制会拒绝调用。

在 VibeGuard 源码目录运行：

```bash
cargo build --locked --manifest-path vibeguard-runtime/Cargo.toml
cd plugins/dsh
npm ci
npm run check
npm test
npm pack --pack-destination dist

dsh plugin --profile demo add ./dist/vibeguard-dsh-0.1.0.tgz
dsh --profile demo --dump-config
```

插件包插入 `vibeguard` Cordis 条目，需要 profile 的普通 DSH base bundle 和 shell 服务。在 profile 的 `cordis.patch.yml` 覆盖：

```yaml
- id: vibeguard
  config:
    runtimePath: /absolute/path/to/vibeguard-runtime
    stateDir: /absolute/path/to/vibeguard-state
    timeoutMs: 5000
```

空路径选择 `~/.vibeguard/bin/vibeguard-runtime` 和 `~/.vibeguard/state`。缺二进制时加载失败并提示构建命令，不自动下载。`timeoutMs` 限制每次运行时调用。可以直接指向 `vibeguard-runtime/target/debug/vibeguard-runtime`。

运行时遵循 profile 的 shell 执行器和沙箱。沙箱限制主目录写入时，把 `stateDir` 指向配置工作区内的可写目录；无法写观察时会提示。适配不会添加沙箱豁免。

只保存最新的 `dsh.json` 观察，字段是主机、事件、时间、cwd、调用 ID、结果和可选退出码，不保存原始命令或输出。显示文本不能当作退出码。批准策略拒绝时先保存拒绝事实；执行完成后以实际结果替换。

## 验证

`npm test` 组合真实 Cordis、ToolRuntime、ApprovalService、Session、AgentLoop 和本机 subprocess/shell 服务。测试 Bash 工具只记下调度，不执行输入；危险字符串仅作为 stdin 交给真实 Rust 护栏。覆盖原生审批结果与审计事件、缺审批、取消、运行时/协议错误、结构化结果观察和卸载。

此版本以本地可发布 tgz 交付；npm 发布前按上面的本地包路径安装。

官方接口：[tools](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/core/tools)、[user approval](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/interaction/user-approval)、[shell](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/shell/shell)。官方代码持续变化；上面固定的已发布版本才是实际测试接口。
