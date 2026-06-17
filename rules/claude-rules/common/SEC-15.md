## SEC-15: Hardcoded secrets and credentials (critical)

Secrets are written directly in source code, configuration files, or documentation.
This includes API keys, cloud provider tokens, connection strings, private keys, and
bearer tokens. These credentials can be extracted from version control history even
after removal, leading to unauthorized access and data breaches.

**Fix**: Move all secrets to environment variables or a secret manager. Add `.env`
to `.gitignore`. Use a pre-commit hook to block commits containing secrets.

**Detection capabilities**:
- 100+ patterns covering all major providers
- Configurable dictionary for project-specific patterns
- Connection strings (PostgreSQL, MySQL, MongoDB, Redis, AMQP, MQTT, SMTP)
- Private keys (RSA, EC, DSA, OpenSSH, PGP)
- Bearer tokens and JWT
- Format-specific patterns (JSON, YAML, TOML, Shell, Python, JavaScript)

**Examples**:
```python
# BAD
api_key = "sk-1234567890abcdef1234567890abcdef"
DATABASE_URL = "postgresql://user:pass@host/db"

# GOOD
api_key = os.environ.get("API_KEY")
DATABASE_URL = os.environ["DATABASE_URL"]
```

**Guard script**: `guards/universal/check_secret_leaks.sh`

**Usage**:
```bash
# Pre-commit scan (staged files)
bash guards/universal/check_secret_leaks.sh

# Block on violations
bash guards/universal/check_secret_leaks.sh --strict

# Full project audit
bash guards/universal/check_secret_leaks.sh --full

# Security grading
bash guards/universal/check_secret_leaks.sh --score
```

**Bypass**: Create `data/bypass-scan` file before committing.

**Advice**: Add `data/reports/` to `.gitignore` to prevent committing scan reports.
