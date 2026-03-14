# Security Policy

## Supported Versions

VibeGuard is distributed as a shell/script-based toolchain installed into Claude Code. The following table reflects which release lines receive security updates.

| Version | Supported |
|---------|-----------|
| `main` (latest) | ✅ Active — patches applied immediately |
| Last 30 days of `main` | ✅ Backport considered on a case-by-case basis |
| Older than 30 days (pinned installs) | ❌ Upgrade recommended |

Because VibeGuard has no compiled release artifacts, "version" refers to the Git commit you have installed. Run `git -C ~/vibeguard log -1 --format="%h %ai"` to identify your installed commit.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Please report security issues by emailing **1835304752@qq.com** with the subject line:

```
[SECURITY] <short description>
```

Include in your report:

- A description of the vulnerability and its potential impact
- Steps to reproduce (scripts, hooks configuration, Claude Code version, OS)
- Any proof-of-concept or example output
- Whether you believe this is already being actively exploited

### Response Timeline

| Milestone | Target |
|-----------|--------|
| Acknowledgment | Within **48 hours** of receipt |
| Initial assessment & severity triage | Within **7 days** |
| Fix or mitigation | Within **30 days** for high/critical; 60 days for medium/low |
| Public disclosure | Coordinated with reporter — see Disclosure Policy below |

We will keep you informed at each stage. If you do not receive an acknowledgment within 48 hours, please follow up — your email may have been filtered.

## Disclosure Policy

VibeGuard follows **coordinated disclosure**:

1. Reporter submits vulnerability privately.
2. Maintainer acknowledges and begins investigation within 48 hours.
3. A fix is developed in a private branch and tested.
4. Reporter is given an opportunity to review the fix before release.
5. Fix is merged to `main` and a GitHub Security Advisory is published.
6. Reporter may publish their own write-up **no sooner than 90 days** after initial report, or immediately after the advisory is public — whichever comes first.

If a patch cannot be delivered within 90 days due to complexity, we will negotiate an extension with the reporter and publish a mitigation advisory at the 90-day mark.

## Security Scope

The following issues are considered **in-scope** vulnerabilities for VibeGuard:

### Guard / Hook Bypass
- Techniques that allow a Claude Code agent to bypass `pre-write-guard`, `pre-bash-guard`, `pre-edit-guard`, or `post-edit-guard` without triggering an interception.
- Logic errors in guard scripts that cause them to silently pass dangerous operations (e.g., `rm -rf`, `git push --force`).
- Race conditions or TOCTOU issues in hook execution that allow dangerous commands to slip through.

### Hook Injection
- Malicious content in a project's CLAUDE.md, rules files, or skill files that causes VibeGuard hooks to execute unintended commands.
- Shell injection in guard scripts via unquoted variables or unvalidated input from tool call arguments.

### Credential / Secret Exposure
- Guard scripts or `post-edit-guard` logging output that prints credentials, API keys, or tokens to stdout/stderr or log files.
- `stats.sh`, `metrics-exporter.sh`, or other scripts that inadvertently capture and store sensitive data from the AI tool call context.

### Privilege Escalation
- Setup scripts (`setup.sh`, `install-hook.sh`) that write to system-wide paths or execute with unintended elevated privileges.
- MCP server components that expose local file system access beyond the intended scope.

### Rule Integrity
- Attacks that modify `~/.claude/CLAUDE.md` or the installed rules directory to silently remove or weaken VibeGuard constraints without user awareness.

## Out of Scope

The following are **not** considered security vulnerabilities in VibeGuard:

- Vulnerabilities in Claude Code itself, the Anthropic API, or any third-party AI service — please report those to Anthropic directly.
- A sufficiently capable AI model choosing to ignore rule-based constraints (this is an AI alignment problem, not a VibeGuard security bug).
- Issues that require physical access to a machine already compromised by an attacker.
- Denial-of-service against the local hook execution (e.g., a hook that takes a long time) — these are usability issues, not security vulnerabilities.
- Missing security headers or TLS configuration on the MCP server when running in a local-only development context.
- Security issues in dependencies that have no known exploit path through VibeGuard's usage surface.
- Social-engineering attacks that trick the user into disabling VibeGuard manually.

## Security Best Practices for Users

- **Keep VibeGuard up to date**: `git -C ~/vibeguard pull` regularly to receive the latest guard improvements and patches.
- **Review rules before installation**: Inspect `setup.sh` and the `rules/` directory before running in a production or sensitive environment.
- **Restrict MCP server scope**: If running the MCP server, ensure it is bound to `localhost` only and not exposed to external networks.
- **Audit installed hooks**: Run `bash ~/vibeguard/setup.sh --check` periodically to verify hook integrity.
- **Do not commit secrets to rule files**: VibeGuard rule files may be read by AI agents — never embed credentials there.

## Recognition

We value and appreciate responsible security researchers. Reporters who follow this policy and help improve VibeGuard's security will be recognized in the following ways:

- **Hall of Fame**: Your name (or handle) and a brief description of the finding will be added to this document under the Hall of Fame section below, unless you prefer to remain anonymous.
- **Public acknowledgment**: Credited in the corresponding GitHub Security Advisory.
- We currently do not offer monetary bounties, but we are grateful for your contribution.

To claim recognition, include your preferred name/handle and whether you want to be publicly credited in your initial report.

### Hall of Fame

*No entries yet. Be the first responsible reporter!*

---

This policy is adapted from [GitHub's recommended security policy template](https://docs.github.com/en/code-security/getting-started/adding-a-security-policy-to-your-repository) and [coordinated vulnerability disclosure best practices](https://www.cisa.gov/coordinated-vulnerability-disclosure-process).
