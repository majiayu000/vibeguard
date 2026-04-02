
# Security rules

## SEC-01: SQL/NoSQL/OS Command Injection (Critical)
String concatenation constructs a query or command. Fix: Use parameterized queries; command execution uses array parameter list instead.
```python
cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,)) # Correct
subprocess.run(["ls", "-la", path], check=True) # Correct
```

## SEC-02: Hardcoded Key/Credential/API Key (Critical)
Write the key directly in the code. Fix: Use environment variables or a key manager instead. `.env` added `.gitignore`.

## SEC-03: User input is output directly to HTML without escaping (high)
XSS vulnerabilities. Fix: Use DOMPurify or the framework's own escaping. Direct assignment to `innerHTML` is prohibited.

## SEC-04: API endpoint missing authentication/authorization check (High)
Unprotected API endpoint. Fix: Add authentication middleware or guards.

## SEC-05: Dependency contains known CVE vulnerability (High)
Fix: Run audit commands (`npm audit` / `pip audit` / `govulncheck ./...` / `cargo audit`) to upgrade or replace.

## SEC-06: Use weak encryption algorithm (high)
MD5/SHA1 does password hashing. Fix: Replaced with bcrypt/argon2.

## SEC-07: File path not verified (medium)
Path traversal risk. Fix: Validate and normalize paths, restricting to allowed base directories.

## SEC-08: Server request does not limit the target address (medium)
SSRF risks. Fix: Add destination address whitelist or network layer restriction.

## SEC-09: Unsafe deserialization (medium)
Such as `pickle` / `yaml.load`. Fix: Python uses `yaml.safe_load()` instead to avoid `pickle` handling untrusted data.

## SEC-10: Logs contain sensitive information (medium)
The password and token appear in the log. Fix: Desensitize log output and replace sensitive fields with `***`.
