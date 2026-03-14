# Contributing to VibeGuard

Thank you for your interest in contributing to VibeGuard — the AI anti-hallucination framework for Claude Code. This guide covers everything you need to get started.

---

## Table of Contents

1. [Development Environment Setup](#development-environment-setup)
2. [Contribution Workflow](#contribution-workflow)
3. [Code Review Process and PR Guidelines](#code-review-process-and-pr-guidelines)
4. [Guard Script Development Guide](#guard-script-development-guide)
5. [Code of Conduct](#code-of-conduct)

---

## Development Environment Setup

### Prerequisites

- **Bash** 4.0+ (macOS ships with Bash 3; install via `brew install bash`)
- **Python** 3.11+ (required for Python guards and constraint recommender)
- **Node.js** 20+ (required for the MCP server)
- **Git** 2.30+
- Optional: **shellcheck** for linting shell scripts (`brew install shellcheck`)

### Clone and Install

```bash
# 1. Fork the repo on GitHub, then clone your fork
git clone https://github.com/<your-username>/vibeguard.git
cd vibeguard

# 2. Run the main setup script (installs hooks into ~/.claude/)
bash setup.sh
```

The setup script installs hooks, rules, and commands into `~/.claude/`. It is idempotent — safe to re-run after changes.

### MCP Server Setup

The MCP server lives in `mcp-server/` and is a Node.js/TypeScript package.

```bash
cd mcp-server
npm install
npm run build
```

### Verify Installation

Run all test suites from the repo root to confirm everything is wired correctly:

```bash
# Hook regression tests
bash tests/test_hooks.sh

# Rust guard regression tests
bash tests/test_rust_guards.sh

# Setup regression tests
bash tests/test_setup.sh

# MCP server unit tests
cd mcp-server && npm test
```

All tests must pass on a clean clone before you start making changes.

### CI Validation Scripts

The same scripts run in CI. You can run them locally:

```bash
bash scripts/ci/validate-guards.sh      # all guard scripts executable + valid syntax
bash scripts/ci/validate-hooks.sh       # all hook scripts executable + valid syntax
bash scripts/ci/validate-rules.sh       # rule file format + unique IDs
bash scripts/ci/validate-config-contract.sh
bash scripts/ci/validate-wiring-contract.sh
bash scripts/ci/validate-doc-paths.sh
```

---

## Contribution Workflow

### 1. Fork and Branch

1. Fork the repository on GitHub.
2. Create a feature branch from `main` using the naming convention below.

### Branch Naming Convention

| Prefix | When to use |
|--------|-------------|
| `feat/` | New guard, new hook, new skill, new feature |
| `fix/` | Bug fix in existing guard, hook, or script |
| `docs/` | Documentation-only changes |
| `refactor/` | Internal restructuring with no behaviour change |
| `test/` | Adding or improving tests |
| `chore/` | Build scripts, CI tweaks, dependency updates |

Examples:
```
feat/go-nil-dereference-guard
fix/pre-write-guard-path-escaping
docs/add-contributing-guide
test/rust-guard-regression-edge-cases
```

### 2. Make Your Changes

- Keep changes focused. One logical change per branch.
- Follow the existing code style (shell scripts: `set -euo pipefail`, 2-space indent).
- Do not add features beyond what was requested (rule U-04).
- Do not modify public API signatures without explicit agreement (rule U-01).

### 3. Test Your Changes

Before committing, run the full test suite:

```bash
bash tests/test_hooks.sh
bash tests/test_rust_guards.sh
bash tests/test_setup.sh
bash scripts/ci/validate-guards.sh
bash scripts/ci/validate-hooks.sh
```

For the MCP server:

```bash
cd mcp-server && npm run build && npm test
```

### 4. Commit Message Format

VibeGuard uses **Conventional Commits**:

```
<type>(<scope>): <description>

[optional body]

Signed-off-by: Your Name <your@email.com>
```

**Types**: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

**Scope** (optional, use the affected directory or component):
`hooks`, `guards/rust`, `guards/go`, `guards/python`, `guards/typescript`, `guards/universal`, `rules`, `mcp-server`, `scripts`, `tests`, `docs`

**DCO sign-off is required on every commit.** Use `-s` flag:

```bash
git commit -s -m "feat(guards/go): add nil-dereference guard"
```

Good examples:
```
feat(guards/rust): add check_async_send_sync guard (RS-14)
fix(hooks): handle paths with spaces in pre-write-guard.sh
docs: add guard script development guide to CONTRIBUTING.md
test(guards/typescript): add regression cases for any-abuse guard
chore(mcp-server): bump @modelcontextprotocol/sdk to 1.28.0
```

**Do not** include `Co-Authored-By` lines or any AI-generation markers in commits.

### 5. Open a Pull Request

Push your branch to your fork and open a PR targeting `main` on the upstream repo.

---

## Code Review Process and PR Guidelines

### PR Title and Description

- Title must follow the same Conventional Commits format as your commit messages.
- Description should include:
  - **What**: What does this change do?
  - **Why**: Why is this change needed?
  - **Test plan**: How did you verify correctness?
  - For new guards: the rule ID being implemented and example violation output.

### PR Checklist

Before requesting review, confirm:

- [ ] All tests pass locally (`bash tests/test_hooks.sh`, etc.)
- [ ] `bash scripts/ci/validate-guards.sh` passes (if touching guards)
- [ ] `bash scripts/ci/validate-hooks.sh` passes (if touching hooks)
- [ ] New shell scripts are executable (`chmod +x script.sh`)
- [ ] New guard scripts source `common.sh` where appropriate
- [ ] DCO sign-off present on all commits
- [ ] No hardcoded paths to local machines or private directories
- [ ] No secrets, tokens, or credentials in any file

### Review Criteria

Reviewers will check in this priority order:

1. **Security** — no command injection, no hardcoded secrets, safe path handling
2. **Logic** — guard detects what it claims; no false positives on common patterns
3. **Quality** — output format matches `[RULE-ID] file:line description. Fix: ...`
4. **Performance** — large repos should not cause guards to time out

### Merging

- At least one approving review is required before merging.
- The branch must be up to date with `main` before merge.
- Squash merges are preferred for small fixes; merge commits are used for larger features to preserve history.

---

## Guard Script Development Guide

Guards are the core of VibeGuard. They are static analysis scripts invoked by `/vibeguard:check` and CI.

### Directory Layout

```
guards/
├── universal/        # Language-agnostic checks (code slop, dependency layers, circular deps)
├── rust/             # Rust-specific guards
├── go/               # Go-specific guards
├── python/           # Python-specific guards
└── typescript/       # TypeScript-specific guards
```

### Anatomy of a Guard Script

Every guard script follows the same structure:

```bash
#!/usr/bin/env bash
# VibeGuard <Language> Guard: <one-line description> (<RULE-ID>)
#
# <Detailed description of what is detected and why it matters>
# Usage:
#   bash check_my_guard.sh [target_dir]
#   bash check_my_guard.sh --strict [target_dir]  # exit 1 on violations
#
# Excludes:
#   - <list any files/dirs excluded, e.g. test directories>

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

# --- detection logic here ---

# Report violations
if [[ -s "${TMPFILE}" ]]; then
  echo "[RULE-ID] Violations found:"
  cat "${TMPFILE}"
  if [[ "${STRICT:-0}" == "1" ]]; then
    exit 1
  fi
fi
```

### Shared Utilities (`common.sh`)

Each language directory has a `common.sh` that provides:

| Function | Purpose |
|----------|---------|
| `parse_guard_args "$@"` | Sets `$TARGET_DIR` and `$STRICT` from CLI args |
| `create_tmpfile` | Creates a temp file that auto-cleans on exit |
| `list_rs_files <dir>` | Lists `.rs` files (prefers `git ls-files`) |

Always `source common.sh` at the top of language-specific guards.

### Output Format

All violations must follow this exact format so tooling can parse them:

```
[RULE-ID] path/to/file.ext:42 Short description. Fix: Specific remediation.
```

Examples:
```
[RS-03] src/main.rs:17 .unwrap() in production code. Fix: Use ? operator or match.
[TS-02] src/api.ts:89 console.log() left in production code. Fix: Remove or replace with logger.
[GO-01] internal/handler.go:33 Error return value ignored. Fix: Assign to _ or handle.
```

### Rule ID Assignment

Use the language prefix and next available number:

| Language | Prefix | Example |
|----------|--------|---------|
| Rust | `RS-` | `RS-14` |
| Go | `GO-` | `GO-04` |
| Python | `PY-` | `PY-03` |
| TypeScript | `TS-` | `TS-05` |
| Universal | `U-` | `U-25` |

Check existing guards and `rules/` to find the current highest number before assigning a new ID.

### Writing Tests for Your Guard

Add regression tests to the appropriate test file in `tests/`:

```bash
# In tests/test_rust_guards.sh (or equivalent)
header "RS-14: My New Guard"

# Test: should detect violation
output=$(bash "${GUARDS_DIR}/rust/check_my_guard.sh" "${FIXTURES_DIR}/bad_example" 2>&1 || true)
assert_contains "$output" "[RS-14]" "detects violation in bad example"

# Test: should not flag clean code
output=$(bash "${GUARDS_DIR}/rust/check_my_guard.sh" "${FIXTURES_DIR}/clean_example" 2>&1 || true)
assert_not_contains "$output" "[RS-14]" "no false positive on clean code"
```

Create minimal fixture files under `tests/fixtures/` (or inline synthetic content) that cover:
- A clear positive case (the bad pattern the guard should catch)
- A clean case (valid code that must not be flagged)
- Any common false-positive patterns (e.g., the pattern in a comment or test file)

### Making a Guard Executable

Scripts must be executable before committing:

```bash
chmod +x guards/<language>/check_my_guard.sh
```

The CI `validate-guards.sh` script will fail if any guard is not executable.

### Testing Locally

```bash
# Syntax check
bash -n guards/rust/check_my_guard.sh

# Run against a target directory
bash guards/rust/check_my_guard.sh /path/to/rust/project

# Run in strict mode (exit 1 on violations)
bash guards/rust/check_my_guard.sh --strict /path/to/rust/project

# Run full validation
bash scripts/ci/validate-guards.sh
```

### Wiring a Guard into `/vibeguard:check`

After writing and testing your guard, add it to the appropriate section in the check command at `.claude/commands/vibeguard/check.md`. Follow the existing pattern for how guards are invoked in the check workflow.

---

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). By participating, you agree to uphold a welcoming, harassment-free environment for all contributors.

To report unacceptable behaviour, open a private issue on GitHub or contact the maintainers directly via the email listed in the repository profile.
