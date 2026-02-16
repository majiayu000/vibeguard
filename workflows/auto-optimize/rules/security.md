# Security Rules（安全规则）

安全审查的检查项和修复模式。从 OWASP Top 10 和常见安全反模式提取。

## 扫描检查项

| ID | 类别 | 检查项 | 严重度 |
|----|------|--------|--------|
| SEC-01 | Injection | SQL/NoSQL/OS 命令/LDAP 注入 | 严重 |
| SEC-02 | Secrets | 代码中硬编码密钥/凭证/API Key | 严重 |
| SEC-03 | XSS | 用户输入未转义直接输出到 HTML | 高 |
| SEC-04 | Auth | API 端点缺少认证/授权检查 | 高 |
| SEC-05 | Deps | 依赖包含已知 CVE 漏洞 | 高 |
| SEC-06 | Crypto | 使用弱加密算法（MD5/SHA1 做密码哈希） | 高 |
| SEC-07 | Path | 文件路径未验证（路径遍历风险） | 中 |
| SEC-08 | SSRF | 服务端请求未限制目标地址 | 中 |
| SEC-09 | Deserial | 不安全的反序列化（pickle/yaml.load） | 中 |
| SEC-10 | Logging | 日志中包含敏感信息（密码、token） | 中 |

## 密钥管理规范

- 密钥/凭证通过环境变量或密钥管理器获取
- `.env` 文件必须在 `.gitignore` 中
- 不在代码注释中留下密钥示例
- CI/CD 使用 secrets 管理，不硬编码

## 输入消毒模式

```python
# Python — 参数化查询
cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,))  # 正确
cursor.execute(f"SELECT * FROM users WHERE id = {user_id}")       # 错误

# Python — 命令执行
subprocess.run(["ls", "-la", path], check=True)  # 正确
os.system(f"ls -la {path}")                       # 错误
```

```typescript
// TypeScript — 防 XSS
const safe = DOMPurify.sanitize(userInput);  // 正确
element.innerHTML = userInput;                // 错误

// TypeScript — 参数化查询
db.query("SELECT * FROM users WHERE id = $1", [userId]);  // 正确
db.query(`SELECT * FROM users WHERE id = ${userId}`);      // 错误
```

```go
// Go — 参数化查询
db.Query("SELECT * FROM users WHERE id = ?", userID)  // 正确
db.Query("SELECT * FROM users WHERE id = " + userID)  // 错误

// Go — 命令执行
exec.Command("ls", "-la", path)                        // 正确
exec.Command("sh", "-c", "ls -la " + path)             // 错误
```

## 依赖安全扫描命令

| 语言 | 命令 |
|------|------|
| Node.js | `npm audit` / `yarn audit` |
| Python | `pip audit` / `safety check` |
| Go | `govulncheck ./...` |
| Rust | `cargo audit` |

## FIX/SKIP 判断

| 条件 | 判定 |
|------|------|
| 任何注入漏洞 | FIX — 严重，立即修复 |
| 硬编码密钥 | FIX — 严重，立即修复 |
| 已知 CVE 依赖 | FIX — 升级或替换 |
| 弱加密算法 | FIX — 替换为安全算法 |
| 缺少输入验证（系统边界） | FIX — 添加验证 |
| 缺少输入验证（内部函数） | SKIP — 信任内部调用 |
| 日志中的敏感信息 | FIX — 脱敏处理 |
