# claude-md/ 目录

VibeGuard 规则注入机制。此目录包含将 VibeGuard 规则注入到用户 `~/.claude/CLAUDE.md` 的模板文件。

## 工作方式

1. `vibeguard-rules.md` 包含注入到 CLAUDE.md 的规则内容
2. `setup.sh` 通过 `<!-- vibeguard-start -->` / `<!-- vibeguard-end -->` 标记管理注入区域
3. 重新运行 `setup.sh` 会更新已有标记区域内的内容，不影响用户自定义内容

## 修改规则

1. 编辑 `vibeguard-rules.md`
2. 运行 `bash setup.sh` 重新注入
3. 新 Claude Code 会话中生效
