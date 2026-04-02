# Security Rules

Security review check items and remediation modes. Extracted from OWASP Top 10 and common security anti-patterns.

## Scan check items

| ID | Category | Check Item | Severity |
|----|------|--------|--------|
| SEC-01 | Injection | SQL/NoSQL/OS Command/LDAP Injection | Critical |
| SEC-02 | Secrets | Hardcoded secrets/credentials/API Key in code | Critical |
| SEC-03 | XSS | User input is output directly to HTML without escaping | High |
| SEC-04 | Auth | API endpoint missing authentication/authorization check | High |
| SEC-05 | Deps | Dependency contains known CVE vulnerability | High |
| SEC-06 | Crypto | Use weak encryption algorithm (MD5/SHA1 for password hashing) | High |
| SEC-07 | Path | File path not verified (path traversal risk) | Medium |
| SEC-08 | SSRF | Server request unrestricted destination address | Medium |
| SEC-09 | Deserial | Unsafe deserialization (pickle/yaml.load) | Medium |
| SEC-10 | Logging | The log contains sensitive information (password, token) | Medium |

## Key management specifications

- Keys/credentials obtained via environment variables or key manager
- `.env` file must be in `.gitignore`
- Don't leave key examples in code comments
- CI/CD uses secrets management, no hard coding

## Enter disinfection mode

```python
# Python — Parameterized queries
cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,)) # Correct
cursor.execute(f"SELECT * FROM users WHERE id = {user_id}") # Error

# Python — command execution
subprocess.run(["ls", "-la", path], check=True) # Correct
os.system(f"ls -la {path}") # Error
```

```typescript
// TypeScript — Anti-XSS
const safe = DOMPurify.sanitize(userInput); // Correct
element.innerHTML = userInput; // Error

// TypeScript — parameterized queries
db.query("SELECT * FROM users WHERE id = $1", [userId]); // Correct
db.query(`SELECT * FROM users WHERE id = ${userId}`); // Error
```

```go
// Go — parameterized queries
db.Query("SELECT * FROM users WHERE id = ?", userID) // Correct
db.Query("SELECT * FROM users WHERE id = " + userID) // Error

// Go — command execution
exec.Command("ls", "-la", path) // Correct
exec.Command("sh", "-c", "ls -la " + path) // Error
```

## Depend on security scan command

| Language | Commands |
|------|------|
| Node.js | `npm audit` / `yarn audit` |
| Python | `pip audit` / `safety check` |
| Go | `govulncheck ./...` |
| Rust | `cargo audit` |

## FIX/SKIP judgment

| Condition | Judgment |
|------|------|
| Any injection vulnerability | FIX — Critical, fix immediately |
| Hardcoded keys | FIX — critical, fix now |
| Known CVE dependencies | FIX — upgrade or replace |
| Weak encryption algorithm | FIX — Replace with secure algorithm |
| Missing input validation (system boundary) | FIX — Add validation |
| Missing input validation (internal function) | SKIP — Trust internal calls |
| Sensitive information in logs | FIX — desensitization |
