---
description: "配置文件和环境变量的保护规则"
globs: ["**/.env*", "**/config/**", "**/*.yaml", "**/*.yml", "**/*.toml", "**/docker-compose*"]
---

# Config Protection

- .env 文件修改前必须征得用户同意
- 禁止在配置文件中硬编码密钥、token、密码
- 新增环境变量必须在 .env.example 中添加对应条目（不含真实值）
- Docker/K8s 配置变更前确认不影响现有部署
- 端口分配检查冲突：修改前用 lsof 确认端口空闲
