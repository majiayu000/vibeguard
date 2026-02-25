---
description: "API 路由和控制器的安全规则"
globs: ["**/api/**", "**/routes/**", "**/controllers/**", "**/handlers/**"]
---

# API Security Rules

- 所有用户输入必须验证和消毒，不信任任何外部数据
- SQL 查询必须使用参数化查询，禁止字符串拼接
- 敏感数据（密码、token）禁止出现在日志和响应中
- API 响应禁止泄露内部错误堆栈，生产环境返回通用错误信息
- 认证/授权检查必须在路由级别强制执行，不依赖前端
- Rate limiting 必须在网关或中间件层实现
