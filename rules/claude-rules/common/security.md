
# 安全规则

## SEC-01: SQL/NoSQL/OS 命令注入（严重）
字符串拼接构造查询或命令。修复：使用参数化查询；命令执行改用数组参数列表。
```python
cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,))  # 正确
subprocess.run(["ls", "-la", path], check=True)                   # 正确
```

## SEC-02: 硬编码密钥/凭证/API Key（严重）
代码中直接写入密钥。修复：改用环境变量或密钥管理器。`.env` 加入 `.gitignore`。

## SEC-03: 用户输入未转义直接输出到 HTML（高）
XSS 漏洞。修复：使用 DOMPurify 或框架自带转义。禁止直接赋值 `innerHTML`。

## SEC-04: API 端点缺少认证/授权检查（高）
未保护的 API 端点。修复：添加认证中间件或守卫。

## SEC-05: 依赖包含已知 CVE 漏洞（高）
修复：运行审计命令（`npm audit` / `pip audit` / `govulncheck ./...` / `cargo audit`）升级或替换。

## SEC-06: 使用弱加密算法（高）
MD5/SHA1 做密码哈希。修复：替换为 bcrypt/argon2。

## SEC-07: 文件路径未验证（中）
路径遍历风险。修复：验证并规范化路径，限制在允许的基目录内。

## SEC-08: 服务端请求未限制目标地址（中）
SSRF 风险。修复：添加目标地址白名单或网络层限制。

## SEC-09: 不安全的反序列化（中）
如 `pickle` / `yaml.load`。修复：Python 改用 `yaml.safe_load()`，避免 `pickle` 处理不可信数据。

## SEC-10: 日志中包含敏感信息（中）
密码、token 出现在日志中。修复：对日志输出脱敏处理，敏感字段替换为 `***`。
