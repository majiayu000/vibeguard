# VibeGuard

VibeGuard 是一个 Rust 命令行程序，做两件事：拒绝有限几类破坏性 Bash 命令，以及不让源文件涨过 800 行（见[行数上限](#行数上限)）。另外提供可选的 Git pre-push 检查和安装诊断。

这里的 runtime 是本地命令行程序。宿主调用 hook 时启动它，处理一个事件后退出；这指“一次调用结束”，与退出 Rust 技术路线无关。新版删除了长期代理工具调用的 app-server wrapper。

[英文说明](../README.md) · [运行契约](runtime-contract.md)

一条命令即可安装：自动下载适合系统与 CPU 的最新发布包，按 `SHA256SUMS` 校验后执行 `install`。只需要 `curl`、`tar` 和 `shasum`/`sha256sum`，不需要 Rust 工具链或 Python：

```bash
curl -fsSL https://raw.githubusercontent.com/majiayu000/vibeguard/main/install.sh | bash -s -- claude --dry-run
curl -fsSL https://raw.githubusercontent.com/majiayu000/vibeguard/main/install.sh | bash -s -- claude
```

把 `claude` 换成 `codex` 或 `grok` 即可；在 `bash` 前设置 `VIBEGUARD_VERSION=v2.3.0` 可固定版本。也可以手动完成：

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

安装前可用 `install codex --dry-run`（或 `claude` / `grok` / `git` / `git-size`）只读预览将改动的文件、注册命令和持久锁文件。它复用安装校验，不创建目录，不获取锁，不证明写入权限或实际防护。安装会保留无关的 hook、用户说明和 `disableAllHooks` 设置；已禁用的 hooks 仍需用户检查后启用。

从源码构建则在源码目录运行（需要 `cargo`；没有时 `setup.sh` 会停止并提示改用 `install.sh`）：

```bash
bash setup.sh install codex --dry-run
bash setup.sh install codex
# 或 Claude Code：
bash setup.sh install claude
# 或 Grok：
bash setup.sh install grok
~/.vibeguard/bin/vibeguard-runtime status codex
```

需要仓库指定的 Rust 工具链。原生安装支持 macOS、Linux、WSL。Windows x64 新增实验性 Claude Code + Git Bash 支持，要求 Claude Code 2.1.139 或更新版本；从 Windows 发布包解压后在 PowerShell 运行 `./install.ps1 -DryRun` 预览，再运行 `./install.ps1` 安装。也可单独下载脚本，它会下载最新 Windows 发布包并核对 SHA256SUMS。发布包缺失时会报错，不会退回安装其他平台版本。PowerShell/cmd 命令语法和 Windows 原生 Codex、Grok、Git hook 安装暂不覆盖。Windows 真实 Claude Code 会话的 hook 触发仍待验证，详见 [Windows 安装说明](../README.md#native-windows-experimental-claude-code--git-bash)。安装注册所选宿主的 hooks，并移除已有的 `vibeguard-core` 受管说明块，保留周围用户内容；不会创建说明文件。重启宿主并检查 hook 信任设置。

安装不再向全局说明注入通用原则或规则查询指令。

Grok 安装在 `$GROK_HOME`（默认 `~/.grok`）写入 `hooks/vibeguard.json`，支持 shell 执行前、执行后与调用失败事件，不创建默认指令文件。更新共享二进制后，Grok 从 Claude 继承的 VibeGuard hooks 也能直接处理 Grok 格式，观察写入独立的 `grok.json`；不需要 Python 脚本，也不修改 `compat.claude.hooks`。两套注册同时存在时可能重复检查，使用相同策略与最近观察。`status grok` 检查原生注册，不认证继承的 hooks 或宿主最终策略；卸载使用 `uninstall grok`。

## 行数上限

源文件（`.rs`、`.py`、`.ts`、`.go`、`.swift` 等）不能超过 800 行且比原来更长；文档、数据和标记文件不计。Agent 写文件的方式不止一种，所以分三处检查：

| 时机 | 看什么 | 宿主 | 结果 | 怎么启用 |
|---|---|---|---|---|
| 编辑前 | `Write`、`Edit`、`MultiEdit` | Claude Code | 拒绝这次编辑 | `install claude` |
| Bash 执行后 | 仓库里显示有改动的文件 | Claude Code、Codex | 提醒 Agent，不拦截 | `install claude`、`install codex` |
| 提交时 | 暂存的内容，不管怎么写进去的 | 所有会提交的工具 | 拒绝这次提交 | `install git-size`，整台机器装一次 |

只有提交时这一层能覆盖所有写法。装一次，这台机器上的所有仓库都生效，包括以后新建的：

```bash
~/.vibeguard/bin/vibeguard-runtime install git-size --dry-run
~/.vibeguard/bin/vibeguard-runtime install git-size
~/.vibeguard/bin/vibeguard-runtime status git-size
~/.vibeguard/bin/vibeguard-runtime uninstall git-size
```

它不会往你的仓库里加任何东西。想在某个仓库关掉（比如别人的项目本来就有大文件）：

```bash
git -C /absolute/path/to/repository config vibeguard.sizeLimit false
```

它拿暂存内容和 `HEAD` 比，不需要维护大文件清单；和 `install git` 分开，不会带上 push 规则。安装方式取决于全局 `core.hooksPath`：

- **没有设置：** 让 Git 指向 `~/.vibeguard/git-hooks`，里面的 hook 会接着运行每个仓库自己的 hook，所以它们照常工作。卸载时会取消这个设置。
- **已被其他工具设置：** 在那个工具的 pre-commit 脚本开头加一段带标记的内容，卸载时恢复原文。如果那个工具重写了脚本，`status git-size` 能看出这段没了，再运行一次 install 即可。不是 shell 脚本的 hook 不会被改动，安装会报错说明。

程序丢失或检查本身出错时，提交照常进行，最多给一条警告：这里出问题不能卡住整台机器的提交。

已知缺口：

- `git commit --no-verify` 能跳过提交检查；rebase 和 fast-forward 合并不触发。
- 仓库自己设置了 `core.hooksPath`（比如 Husky）时不会运行。
- Bash 提醒看的是整个仓库，可能报告其他会话未提交的增长；目录放在 shell 变量里时跟不过去。
- Grok 和 DSH 收不到提醒，Codex 的 `apply_patch` 要到提交时才会被发现。

从 2.1 升级：重新运行 `install claude` 才会启用编辑前检查。已经超限的文件不会自动变短，要有人去拆。

## 能力与边界

编译器、Clippy、Ruff、ESLint、Go 工具负责各自专业检查。

个人偏好直接放进宿主全局指令，项目事实放进仓库指令。当前上下文或交接摘要已有相关指导时直接沿用；只有细节缺失、来源已变更或用户要求核对时才重读，不在每次追问或任务转场时重新读取一份契约。VibeGuard 不改写周围的用户自有指令。

| 能力 | 边界 |
|---|---|
| Bash 事前检查 | 拒绝有限几类破坏性命令写法，不是完整 shell 解析器或沙箱。 |
| 编辑前（Claude Code） | `Write`/`Edit`/`MultiEdit` 会让源文件超过 800 行且比现在更长时拒绝；新文件不能超限，已超限的旧文件只能变短或持平。无法预测结果的编辑（文件不存在、原文不匹配）交给宿主工具自己报错。 |
| Write 前，需手动开启（Claude Code） | 钩子环境里设 `VIBEGUARD_TEMP_PAGES=deny` 后，拒绝用 `Write` 把 `.html`、`.htm` 文件写进临时目录，因为系统之后会删掉。默认关闭。通过 Bash 写的页面看不到。 |
| Bash 执行后（Claude Code、Codex） | 告诉 Agent 哪些源文件涨过了 800 行，同一文件同一行数只提醒一次，不改变任何决定。 |
| Git pre-commit（`install git-size`） | 提交会让源文件超过 800 行且比原来更长时拒绝。详见[行数上限](#行数上限)。 |
| Git pre-push | 拒绝远端 ref 删除和已有 tag 替换；分支须直接指向 commit 并满足快进关系，其他已有 ref 解引用 tag 后检查提交祖先关系。不支持的非提交目标明确拒绝，缺失对象单独报错。需单独安装，详见 [runtime contract](runtime-contract.md)。 |
| 状态与结果 | 区分已配置、执行位完整、最近事件和宿主信任未知；规则文字不参与安装完整性判断，不认证“任务已验证”。 |

已移除规则库与 `rules` 命令（2.2.0）、弱语义扫描、包管理器改写、Stop 计数与测试关键词判断、自动学习、价值评分及重复工作流。提醒覆盖随之减少，原生宿主不是旧检查的等价替代。

`uninstall codex`、`uninstall claude` 或 `uninstall grok` 移除所选集成和观察文件，共享二进制仍保留。没有旧命令、旧 ID 或旧数据兼容。已有 v1 安装先按对应旧版说明卸载，新版不做通用旧版清理。

Claude 安装和重装会专项移除已退役的 `skills-loader.sh` 命令注册，包括手动添加的重复项。仅识别 VibeGuard 已知安装/发布路径的简单调用（可经 `bash` 或 `sh`）及旧 `.vibeguard/run-hook.sh skills-loader.sh` 包装调用，保留任意其他路径中的同名脚本；保留同组其他 hook 和属性，仅删除因此变空的分组。`--dry-run` 显示移除数量而不写入；不扫描技能或删除旧版文件，`status` 仍只读。匹配边界见 [安装契约](runtime-contract.md#installation)。

`status`、`install` 和 `uninstall` 会附带只读的 `legacy` 清单：已知 v1 hook 命令、`<!-- vibeguard-start -->` 区域、`~/.vibeguard` 下的 v1 文件、launchd/systemd 单元，以及在所选 home 就是本账户 home 时的账户 crontab。`--repo` 额外查看该仓库根目录说明和 `pre-commit`/`pre-push`。换一个 `--home` 时不读取账户 crontab。`owned` 和 `suspected` 只表示文件在场，不表示这些命令执行过，也不会删除它们。

先备份清单里的文件。v1 源码目录执行 `bash setup.sh --clean`；v1 发布快照执行 `bash ~/.vibeguard/dist/current/setup.sh --clean`。删掉源码目录不会卸掉 hook 和定时任务。然后再安装 v2：源码用 `bash setup.sh install codex`，解压后的发布包用 `./vibeguard-runtime install codex`。重启宿主后查看 `status`。

完整决策见 [Rust 重构方案](../plan/2026-09-17-frontier-model-reconstruction.md) 和 [125 条对照](../plan/2026-09-17-rule-by-rule-audit.md)。开发检查运行 `bash scripts/local-contract-check.sh`。模型收益按 [评测协议](../eval/README.md) 单独验证，代码测试不能证明对 Astra/Fable 的生产率提升。

DeepSeek Harness 可使用 [DSH Bash 适配](../plugins/dsh/README.zh.md)，复用 Rust 命令策略与结果观察，并走 DSH 原生审批。
