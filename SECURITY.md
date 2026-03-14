# Security Policy

## Supported Versions

The following versions of VibeGuard receive security updates:

| Version | Supported          |
| ------- | ------------------ |
| latest (main) | :white_check_mark: |
| < 1 month old releases | :white_check_mark: |
| Older releases | :x: |

VibeGuard is distributed as scripts and configuration files rather than versioned binaries. Security fixes are applied to the `main` branch and users are expected to re-run `setup.sh` to pick up updates.

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

### Contact

Send vulnerability reports to: **1835304752@qq.com**

Include the subject line: `[VibeGuard Security] <brief description>`

### What to Include

- Description of the vulnerability and its potential impact
- Steps to reproduce (proof-of-concept scripts or configurations welcome)
- Affected components (guard scripts, hooks, rules, setup scripts)
- Your suggested fix or mitigation (optional but appreciated)

### Response Timeline

| Milestone | Target |
| --------- | ------ |
| Acknowledgment | Within **48 hours** of receipt |
| Initial assessment & severity triage | Within **7 days** |
| Fix or mitigation patch | Within **30 days** for High/Critical; **90 days** for Medium/Low |
| Public disclosure | After fix is available and coordinated with reporter |

If you do not receive acknowledgment within 48 hours, follow up at the same email address.

## Disclosure Policy

VibeGuard follows **coordinated disclosure**:

1. Reporter submits vulnerability details privately.
2. Maintainers acknowledge, triage, and develop a fix.
3. A **90-day disclosure window** begins from the date of acknowledgment.
4. If a fix is ready before 90 days, disclosure is coordinated with the reporter and announced alongside the patch.
5. If 90 days elapse without a fix, the reporter may disclose at their discretion. Maintainers will notify the reporter of any delays as early as possible.
6. Critical vulnerabilities with active exploitation may be disclosed on an accelerated timeline with mutual agreement.

We ask reporters to refrain from public disclosure, denial-of-service testing against live systems, or accessing data that does not belong to them during the coordinated window.

## Security Scope

The following issues are considered **in scope** for VibeGuard:

### Guard & Hook Security
- **Guard script bypass** — any technique that allows AI-generated code to pass through a pre/post hook without triggering the intended check (e.g., crafted filenames, encoding tricks, shell metacharacter injection into guard input).
- **Hook injection** — injecting arbitrary shell commands through hook parameters, environment variables, or file content processed by hook scripts.
- **Stop hook infinite loop exploitation** — abusing the `exit 2` re-prompt mechanism in `stop-guard.sh` to cause uncontrolled recursive invocations or resource exhaustion.

### Credential & Data Exposure
- **Credential exposure in logs** — API keys, tokens, or secrets appearing in `hooks/log.sh` output or any VibeGuard log files.
- **Sensitive data leakage** — guard outputs or rule injection that causes Claude Code to emit secrets into generated code or commit messages.

### Rule Injection & Integrity
- **CLAUDE.md injection** — malicious content written to `~/.claude/CLAUDE.md` or project-level CLAUDE.md files through VibeGuard's `setup.sh` or rule-loading scripts that could alter AI behavior in unintended ways.
- **Skills/blueprint tampering** — unauthorized modification of skill or blueprint files that changes the behavior of `skills-loader.sh` or blueprint runners.

### Setup & Installation
- **setup.sh privilege escalation** — the setup script running with elevated privileges or creating files/directories with insecure permissions.
- **Supply chain issues** — compromised dependencies or download sources in `setup.sh` (e.g., fetching remote scripts without integrity verification).

### Pre-commit Guard
- **pre-commit-guard.sh bypass** — techniques that allow secrets, force-pushes, or AI markers to pass the pre-commit check undetected.

## Out of Scope

The following are **not** considered security vulnerabilities for VibeGuard:

- Vulnerabilities in third-party tools that VibeGuard integrates with (Claude Code, Codex CLI, GitHub Actions) — report these to the respective vendors.
- Social engineering attacks against maintainers.
- Denial-of-service attacks against GitHub infrastructure or the public repository.
- Issues that require physical access to the user's machine.
- Theoretical vulnerabilities without a realistic attack path.
- Missing security headers or TLS configuration (VibeGuard has no web server component).
- Rate limiting or brute-force on the email contact address.
- Findings from automated scanners submitted without manual verification.
- Guard rules that a user intentionally disables or modifies in their own environment.

## Security Best Practices for Users

- Review `setup.sh` before running — it writes to `~/.claude/CLAUDE.md` and installs hooks globally.
- Keep VibeGuard up to date by periodically pulling `main` and re-running `setup.sh`.
- Do not commit `.env` files or credentials to repositories protected by VibeGuard; the pre-commit guard is a defense-in-depth measure, not a replacement for proper secret management.
- Audit hook scripts when running in CI environments with elevated permissions.

## Recognition

We are grateful to security researchers who help keep VibeGuard safe. Reporters of valid, in-scope vulnerabilities will be:

- Credited by name (or handle) in the release notes / CHANGELOG for the fixing version, unless they prefer to remain anonymous.
- Listed in a **Hall of Thanks** section below once it is established.
- Given advance notice of the public disclosure so they can coordinate their own write-up.

We do not currently offer a monetary bug bounty, but we deeply value responsible disclosure and will acknowledge contributions publicly.

### Hall of Thanks

*No reports received yet. Be the first!*
