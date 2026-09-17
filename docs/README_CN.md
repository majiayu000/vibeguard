# VibeGuard v2

VibeGuard 继续用 Rust 实现，提供规则查询、原生 Bash hooks、显式 Git pre-push 检查，以及安装和诊断。

这里的 runtime 是本地命令行程序。宿主调用 hook 时启动它，处理一个事件后退出；这指“一次调用结束”，与退出 Rust 技术路线无关。新版删除了长期代理工具调用的 app-server wrapper。

[英文说明](../README.md) · [运行契约](runtime-contract.md) · [75 个规则主题](rule-reference.md)

在源码目录运行：

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
| Git pre-push | 根据真实提交关系拒绝非快进更新和远端 ref 删除，需单独安装。 |
| 状态与结果 | 区分已配置、执行位完整、最近事件和宿主信任未知，不认证“任务已验证”。 |
| 规则 | 保留适用条件与例外，辅助判断，不按等级触发通用硬门禁。 |

已移除弱语义扫描、包管理器改写、Stop 计数与测试关键词判断、自动学习、价值评分及重复工作流。提醒覆盖随之减少，原生宿主不是旧检查的等价替代。

`uninstall codex` 或 `uninstall claude` 移除所选集成和观察文件，共享二进制仍保留。没有旧命令、旧 ID 或旧数据兼容。已有 v1 安装先按对应旧版说明卸载，新版不自动清理旧受管区。

完整决策见 [Rust 重构方案](../plan/2026-09-17-frontier-model-reconstruction.md) 和 [125 条对照](../plan/2026-09-17-rule-by-rule-audit.md)。开发检查运行 `bash scripts/local-contract-check.sh`。模型收益按 [评测协议](../eval/README.md) 单独验证，代码测试不能证明对 Astra/Fable 的生产率提升。
