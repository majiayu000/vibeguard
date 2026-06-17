# SEC-15: Secret Leak Detection Guard

Pre-commit guard that scans for hardcoded secrets and credentials before they reach version control.

## Why this matters

Hardcoded secrets are one of the most common security vulnerabilities. Even after removal, credentials can be extracted from git history. This guard provides **active detection and blocking** — not just advisory warnings.

## What it does

| Function | Description |
|----------|-------------|
| `load_patterns()` | Loads patterns from `data/credential-patterns.txt` or uses built-in |
| `check_sensitive_files()` | Blocks `.env`, `.pem`, `.key` before scanning |
| `scan_staged_files()` | Scans staged files (pre-commit mode) |
| `scan_full_project()` | Scans all tracked files in the project |
| `generate_report()` | Generates markdown reports in `data/reports/` |
| Bypass | `touch data/bypass-scan` to skip scan |
| Blocking | `exit 1` in `--strict` mode to block commit |

## Usage

```bash
# Pre-commit scan (staged files)
bash guards/universal/check_secret_leaks.sh

# Block on violations
bash guards/universal/check_secret_leaks.sh --strict

# Full project audit
bash guards/universal/check_secret_leaks.sh --full

# Security grading (A-F)
bash guards/universal/check_secret_leaks.sh --score

# Scan external project (no residues)
bash guards/universal/check_secret_leaks.sh --external /path/to/project

# Custom patterns and output location
bash guards/universal/check_secret_leaks.sh --external --patterns my-patterns.txt --output-dir /tmp/reports /path

# Bypass (create file before commit)
touch data/bypass-scan
git commit
```

## Files

```
guards/universal/
└── check_secret_leaks.sh      # Main guard (625 lines)
rules/claude-rules/common/
└── SEC-12.md                  # Canonical rule
data/
└── credential-patterns.txt    # 100+ patterns
tests/unit/
└── test_secret_leaks.sh       # 13 tests ✅
```

### guards/universal/check_secret_leaks.sh

The main guard script. Handles all scanning modes:

| Mode | Command | Description |
|------|---------|-------------|
| Pre-commit | `bash guards/universal/check_secret_leaks.sh` | Scan staged files |
| Strict | `bash guards/universal/check_secret_leaks.sh --strict` | Block commit on violations |
| Full | `bash guards/universal/check_secret_leaks.sh --full` | Scan all tracked files |
| Score | `bash guards/universal/check_secret_leaks.sh --score` | Grade security (A-F) |
| External | `bash guards/universal/check_secret_leaks.sh --external /path` | Scan without residues |

**Configurable with env vars:**

```bash
VIBEGUARD_PATTERNS_FILE=data/credential-patterns.txt  # custom patterns location
VIBEGUARD_CREDENTIALS_DIR=.vibeguard                   # custom reports directory
```

### data/credential-patterns.txt

Pattern dictionary used by the guard. One regex pattern per line, comments start with `#`.

**This file is designed to grow.** Add your project-specific patterns:

```bash
# Your custom API keys
YOUR_SERVICE_API_KEY=[^#=\s]
YOUR_PROJECT_SECRET=[^#=\s]
```

Reports are saved to `data/reports/` as markdown files.

### rules/claude-rules/common/SEC-12.md

Canonical rule documentation. Defines what SEC-12 covers and how to fix violations.

### tests/unit/test_secret_leaks.sh

Unit tests for the guard:

```bash
bash tests/unit/test_secret_leaks.sh
```

## Customization

### Adding patterns

Edit `data/credential-patterns.txt` to add patterns for your project:

```bash
# One regex per line
MY_API_KEY=[^#=\s]
MY_SECRET_TOKEN=[^#=\s]
```

### Excluding files

The guard automatically excludes:
- `.env` files (unless `--include-env`)
- `node_modules`, `dist`, `build`, `.git`
- Binary files, lock files, minified files

### Bypass

Create `data/bypass-scan` before committing to skip scanning:

```bash
touch data/bypass-scan
git commit
```

The bypass file is automatically removed after use.

## Advice

> **Always add `data/reports/` to your `.gitignore`**
>
> The `data/reports/` folder contains scan reports that may reveal what credentials
> you're protecting against.
>
> ```gitignore
> # Scan reports
> data/reports/
> ```

> **Run from a separate project when scanning external code**
>
> When scanning projects you don't own, use `--external` mode. This scans the
> target without creating any files in their directory. Reports are saved to a
> temp folder or your specified output.
>
> ```bash
> # Scan another project (no residues)
> bash guards/universal/check_secret_leaks.sh --external /path/to/project
>
> # Save reports to specific location
> bash guards/universal/check_secret_leaks.sh --external --output-dir /tmp/reports /path/to/project
> ```
>
> This prevents accidentally leaving credential patterns or scan reports in
> projects you're auditing.

## Detection

Covers 100+ patterns including:
- API keys (OpenAI, Anthropic, AWS, GitHub, GitLab, Slack, Stripe, etc.)
- Connection strings (PostgreSQL, MySQL, MongoDB, Redis, AMQP, MQTT, SMTP)
- Private keys (RSA, EC, DSA, OpenSSH, PGP)
- Bearer tokens and JWT
- Generic secrets in JSON, YAML, TOML, Shell, Python, JavaScript

The pattern dictionary is not exhaustive — it's a starting point. Add your own patterns to improve detection for your specific stack.
