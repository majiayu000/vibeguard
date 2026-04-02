---
description: "Protection rules for configuration files and environment variables"
globs: ["**/.env*", "**/config/**", "**/*.yaml", "**/*.yml", "**/*.toml", "**/docker-compose*"]
---

# Config Protection

- User consent must be obtained before modifying the .env file
- It is prohibited to hardcode keys, tokens, and passwords in configuration files
- New environment variables must add corresponding entries (excluding real values) in .env.example
- Confirm before changing Docker/K8s configuration that it will not affect existing deployments
- Port allocation check conflict: use lsof to confirm that the port is free before modification
