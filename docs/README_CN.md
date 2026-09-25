# VibeGuard v2

VibeGuard 继续用 Rust 实现，提供规则查询、原生 Bash hooks、显式 Git pre-push 检查，以及安装和诊断。

这里的 runtime 是本地命令行程序。宿主调用 hook 时启动它，处理一个事件后退出；这指“一次调用结束”，与退出 Rust 技术路线无关。新版删除了长期代理工具调用的 app-server wrapper。

[英文说明](../README.md) · [运行契约](runtime-contract.md) · [75 个规则主题](rule-reference.md)

从 [Releases](https://github.com/majiayu000/vibeguard/releases) 下载适合系统与 CPU 的 v2 压缩包，解压后在该目录运行，无需源码或 Rust 工具链：

```bash
./vibeguard-runtime install codex
# 或 Claude Code：
./vibeguard-runtime install claude
~/.vibeguard/bin/vibeguard-runtime status codex
~/.vibeguard/bin/vibeguard-runtime uninstall codex
```

压缩包包含可执行文件、英文 README 和 LICENSE。安装将程序复制到 `~/.vibeguard/bin/vibeguard-runtime`；Claude Code 的状态查询和卸载将上面的 `codex` 换为 `claude`。WSL 使用 Linux 包。旧版本资源应使用对应版本的说明。

从源码构建则在源码目录运行：

```bash
bash setup.sh install codex
# 或 Claude Code：
bash setup.sh install claude
~/.vibeguard/bin/vibeguard-runtime rules rust
~/.vibeguard/bin/vibeguard-runtime status codex
```

需要仓库指定的 Rust 工具链。原生安装支持 macOS、Linux、WSL；Windows 原生安装未实现，会明确报错。安装仅修改所选宿主的配置和受管说明块。重启宿主并检查 hook 信任设置。

全局说明只保留六个原则。完整规则嵌入二进制，按 ID 或语言查询，不会每次注入全部主题。编译器、Clippy、Ruff、ESLint、Go 工具负责各自专业检查。

| 能力 | 边界 |
|---|---|
| Bash 事前检查 | 拒绝有限几类破坏性命令写法，不是完整 shell 解析器或沙箱。 |
| Git pre-push | 拒绝远端 ref 删除和已有 tag 替换；分支须直接指向 commit 并满足快进关系，其他已有 ref 解引用 tag 后检查提交祖先关系。不支持的非提交目标明确拒绝，缺失对象单独报错。需单独安装，详见 [runtime contract](runtime-contract.md)。 |
| 状态与结果 | 区分已配置、执行位完整、最近事件和宿主信任未知，不认证“任务已验证”。 |
| 规则 | 保留适用条件与例外，辅助判断，不按等级触发通用硬门禁。 |

已移除弱语义扫描、包管理器改写、Stop 计数与测试关键词判断、自动学习、价值评分及重复工作流。提醒覆盖随之减少，原生宿主不是旧检查的等价替代。

`uninstall codex` 或 `uninstall claude` 移除所选集成和观察文件，共享二进制仍保留。没有旧命令、旧 ID 或旧数据兼容。已有 v1 安装先按对应旧版说明卸载，新版不自动清理旧受管区。

`status`、`install` 和 `uninstall` 会附带只读的 `legacy` 清单：已知 v1 hook 命令、`<!-- vibeguard-start -->` 区域、`~/.vibeguard` 下的 v1 文件、launchd/systemd 单元，以及在所选 home 就是本账户 home 时的账户 crontab。`--repo` 额外查看该仓库根目录说明和 `pre-commit`/`pre-push`。换一个 `--home` 时不读取账户 crontab。`owned` 和 `suspected` 只表示文件在场，不表示这些命令执行过，也不会删除它们。

先备份清单里的文件。v1 源码目录执行 `bash setup.sh --clean`；v1 发布快照执行 `bash ~/.vibeguard/dist/current/setup.sh --clean`。删掉源码目录不会卸掉 hook 和定时任务。然后再安装 v2：源码用 `bash setup.sh install codex`，解压后的发布包用 `./vibeguard-runtime install codex`。重启宿主后查看 `status`。

完整决策见 [Rust 重构方案](../plan/2026-09-17-frontier-model-reconstruction.md) 和 [125 条对照](../plan/2026-09-17-rule-by-rule-audit.md)。开发检查运行 `bash scripts/local-contract-check.sh`。模型收益按 [评测协议](../eval/README.md) 单独验证，代码测试不能证明对 Astra/Fable 的生产率提升。
