# VibeGuard v2

VibeGuard 继续用 Rust 实现，提供规则查询、原生 Bash hooks、显式 Git pre-push 检查，以及安装和诊断。

这里的 runtime 是本地命令行程序。宿主调用 hook 时启动它，处理一个事件后退出；这指“一次调用结束”，与退出 Rust 技术路线无关。新版删除了长期代理工具调用的 app-server wrapper。

[英文说明](../README.md) · [运行契约](runtime-contract.md) · [75 个规则主题](rule-reference.md)

一条命令即可安装：自动下载适合系统与 CPU 的最新发布包，按 `SHA256SUMS` 校验后执行 `install`。只需要 `curl`、`tar` 和 `shasum`/`sha256sum`，不需要 Rust 工具链或 Python：

```bash
curl -fsSL https://raw.githubusercontent.com/majiayu000/vibeguard/main/install.sh | bash -s -- claude --dry-run
curl -fsSL https://raw.githubusercontent.com/majiayu000/vibeguard/main/install.sh | bash -s -- claude
```

把 `claude` 换成 `codex` 或 `grok` 即可；在 `bash` 前设置 `VIBEGUARD_VERSION=v2.1.0` 可固定版本。也可以手动完成：

从 [Releases](https://github.com/majiayu000/vibeguard/releases) 下载适合系统与 CPU 的 v2 压缩包，解压后在该目录运行，无需源码或 Rust 工具链：

```bash
./vibeguard-runtime install codex --dry-run
./vibeguard-runtime install codex
# 或 Claude Code：
./vibeguard-runtime install claude
# 或 Grok：
./vibeguard-runtime install grok
~/.vibeguard/bin/vibeguard-runtime status codex
~/.vibeguard/bin/vibeguard-runtime uninstall codex
```

压缩包包含可执行文件、英文 README 和 LICENSE。安装将程序复制到 `~/.vibeguard/bin/vibeguard-runtime`；Claude Code 的状态查询和卸载将上面的 `codex` 换为 `claude`。WSL 使用 Linux 包。旧版本资源应使用对应版本的说明。

从源码构建则在源码目录运行（需要 `cargo`；没有时 `setup.sh` 会停止并提示改用 `install.sh`）：

安装前可用 `install codex --dry-run`（或 `claude` / `git`）只读预览将改动的文件、注册命令和持久锁文件。它复用安装校验，不创建目录，不获取锁，不证明写入权限或实际防护。安装会保留无关的 hook、用户说明和 `disableAllHooks` 设置；已禁用的 hooks 仍需用户检查后启用。

```bash
bash setup.sh install codex --dry-run
bash setup.sh install codex
# 或 Claude Code：
bash setup.sh install claude
# 或 Grok：
bash setup.sh install grok
~/.vibeguard/bin/vibeguard-runtime rules rust
~/.vibeguard/bin/vibeguard-runtime status codex
```

需要仓库指定的 Rust 工具链。原生安装支持 macOS、Linux、WSL。Windows x64 新增实验性 Claude Code + Git Bash 支持，要求 Claude Code 2.1.139 或更新版本；从 Windows 发布包解压后在 PowerShell 运行 `./install.ps1 -DryRun` 预览，再运行 `./install.ps1` 安装。也可单独下载脚本，它会下载最新 Windows 发布包并核对 SHA256SUMS。发布包缺失时会报错，不会退回安装其他平台版本。PowerShell/cmd 命令语法和 Windows 原生 Codex/Grok/Git 安装暂不覆盖。Windows 真实 Claude Code 会话的 hook 触发仍待验证，详见 [Windows 安装说明](../README.md#native-windows-experimental-claude-code--git-bash)。安装注册所选宿主的 hooks，并移除已有的 `vibeguard-core` 受管说明块，保留周围用户内容；不会创建说明文件。重启宿主并检查 hook 信任设置。

安装不再向全局说明注入通用原则或规则查询指令。

Grok 安装在 `$GROK_HOME`（默认 `~/.grok`）写入 `hooks/vibeguard.json`，支持 shell 执行前、执行后与调用失败事件，不创建默认指令文件。更新共享二进制后，Grok 从 Claude 继承的 VibeGuard hooks 也能直接处理 Grok 格式，观察写入独立的 `grok.json`；不需要 Python 脚本，也不修改 `compat.claude.hooks`。两套注册同时存在时可能重复检查，使用相同策略与最近观察。`status grok` 检查原生注册，不认证继承的 hooks 或宿主最终策略；卸载使用 `uninstall grok`。

完整规则嵌入二进制，按需主动查询；`rules --core` 仍可输出简短参考。规则查询不是开工前置步骤。编译器、Clippy、Ruff、ESLint、Go 工具负责各自专业检查。

通用工程指导维护在规则库，个人偏好直接放进宿主全局指令，项目事实放进仓库指令。当前上下文或交接摘要已有相关指导时直接沿用；只有细节缺失、来源已变更或用户要求核对时才重读，不在每次追问或任务转场时重新读取一份契约。VibeGuard 不改写周围的用户自有指令。

| 能力 | 边界 |
|---|---|
| Bash 事前检查 | 拒绝有限几类破坏性命令写法，不是完整 shell 解析器或沙箱。 |
| Git pre-push | 拒绝远端 ref 删除和已有 tag 替换；分支须直接指向 commit 并满足快进关系，其他已有 ref 解引用 tag 后检查提交祖先关系。不支持的非提交目标明确拒绝，缺失对象单独报错。需单独安装，详见 [runtime contract](runtime-contract.md)。 |
| 状态与结果 | 区分已配置、执行位完整、最近事件和宿主信任未知；规则文字不参与安装完整性判断，不认证“任务已验证”。 |
| 规则 | 保留适用条件与例外，辅助判断，不按等级触发通用硬门禁。 |

已移除弱语义扫描、包管理器改写、Stop 计数与测试关键词判断、自动学习、价值评分及重复工作流。提醒覆盖随之减少，原生宿主不是旧检查的等价替代。

`uninstall codex`、`uninstall claude` 或 `uninstall grok` 移除所选集成和观察文件，共享二进制仍保留。没有旧命令、旧 ID 或旧数据兼容。已有 v1 安装先按对应旧版说明卸载，新版不做通用旧版清理。

Claude 安装和重装会专项移除已退役的 `skills-loader.sh` 命令注册，包括手动添加的重复项。仅识别 VibeGuard 已知安装/发布路径的简单调用（可经 `bash` 或 `sh`）及旧 `.vibeguard/run-hook.sh skills-loader.sh` 包装调用，保留任意其他路径中的同名脚本；保留同组其他 hook 和属性，仅删除因此变空的分组。`--dry-run` 显示移除数量而不写入；不扫描技能或删除旧版文件，`status` 仍只读。匹配边界见 [安装契约](runtime-contract.md#installation)。

`status`、`install` 和 `uninstall` 会附带只读的 `legacy` 清单：已知 v1 hook 命令、`<!-- vibeguard-start -->` 区域、`~/.vibeguard` 下的 v1 文件、launchd/systemd 单元，以及在所选 home 就是本账户 home 时的账户 crontab。`--repo` 额外查看该仓库根目录说明和 `pre-commit`/`pre-push`。换一个 `--home` 时不读取账户 crontab。`owned` 和 `suspected` 只表示文件在场，不表示这些命令执行过，也不会删除它们。

先备份清单里的文件。v1 源码目录执行 `bash setup.sh --clean`；v1 发布快照执行 `bash ~/.vibeguard/dist/current/setup.sh --clean`。删掉源码目录不会卸掉 hook 和定时任务。然后再安装 v2：源码用 `bash setup.sh install codex`，解压后的发布包用 `./vibeguard-runtime install codex`。重启宿主后查看 `status`。

完整决策见 [Rust 重构方案](../plan/2026-09-17-frontier-model-reconstruction.md) 和 [125 条对照](../plan/2026-09-17-rule-by-rule-audit.md)。开发检查运行 `bash scripts/local-contract-check.sh`。模型收益按 [评测协议](../eval/README.md) 单独验证，代码测试不能证明对 Astra/Fable 的生产率提升。

DeepSeek Harness 可使用 [DSH Bash 适配](../plugins/dsh/README.zh.md)，复用 Rust 命令策略与结果观察，并走 DSH 原生审批。
