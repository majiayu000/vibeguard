# Contributing to VibeGuard

Thank you for your interest in contributing to VibeGuard — the AI anti-hallucination guard system for Claude Code. This guide covers everything you need to get started.

---

## Table of Contents

- [Development Environment Setup](#development-environment-setup)
- [Contribution Workflow](#contribution-workflow)
- [Code Review Process and PR Guidelines](#code-review-process-and-pr-guidelines)
- [Guard Script Development Guide](#guard-script-development-guide)
- [Code of Conduct](#code-of-conduct)

---

## Development Environment Setup

### Prerequisites

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| Git  | 2.30+          | Version control |
| Bash | 5.0+           | Hook and guard scripts |
| Node.js | 20.x        | MCP server |
| Python | 3.11+         | Analysis scripts |
| npm  | 10+            | MCP server dependencies |

> **macOS users:** The system Bash (3.x) is too old. Install a modern Bash via `brew install bash`.

### Clone and Install

```bash
# 1. Fork the repository on GitHub, then clone your fork
git clone https://github.com/<your-username>/vibeguard.git
cd vibeguard

# 2. Add the upstream remote
git remote add upstream https://github.com/majiayu000/vibeguard.git

# 3. Run the setup script (installs VibeGuard into ~/.claude/)
bash setup.sh

# 4. Install MCP server dependencies
cd mcp-server
npm ci
cd ..
```

### Running Tests

All test suites should pass before submitting a PR.

```bash
# Bash regression tests
bash tests/test_hooks.sh
bash tests/test_rust_guards.sh
bash tests/test_setup.sh

# MCP server: build and test
cd mcp-server
npm run build
npm test
cd ..

# CI validation scripts (mirrors what GitHub Actions runs)
bash scripts/ci/validate-guards.sh
bash scripts/ci/validate-hooks.sh
bash scripts/ci/validate-rules.sh
bash scripts/ci/validate-config-contract.sh
bash scripts/ci/validate-wiring-contract.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/doc-freshness-check.sh --strict
```

You can also run the full CI suite locally by executing every step in `.github/workflows/ci.yml` in order.

---

## Contribution Workflow

### 1. Sync with Upstream

Before starting any work, bring your fork up to date:

```bash
git fetch upstream
git checkout main
git merge upstream/main
```

### 2. Branch Naming Convention

Create a branch from `main` using one of these prefixes:

| Prefix | When to use |
|--------|-------------|
| `feat/` | New guard, hook, agent, or feature |
| `fix/` | Bug fix in an existing script or rule |
| `refactor/` | Structural change with no behavior change |
| `docs/` | Documentation-only changes |
| `test/` | Adding or improving tests |
| `chore/` | Build, CI, or tooling changes |

```bash
# Examples
git checkout -b feat/typescript-no-floating-promise-guard
git checkout -b fix/pre-bash-guard-false-positive
git checkout -b docs/contributing-guide
```

Keep branch names lowercase with hyphens, and short enough to be readable.

### 3. Commit Message Format

This project follows [Conventional Commits](https://www.conventionalcommits.org/). Every commit **must** include a `Signed-off-by` trailer to satisfy DCO verification.

```
<type>(<scope>): <short description>

[optional body — explain the why, not the what]

Signed-off-by: Your Name <your@email.com>
```

**Types:** `feat` · `fix` · `refactor` · `docs` · `test` · `chore`

**Scopes (optional but recommended):**

| Scope | Covers |
|-------|--------|
| `guards/rust` | Rust guard scripts |
| `guards/go` | Go guard scripts |
| `guards/python` | Python guard scripts |
| `guards/typescript` | TypeScript guard scripts |
| `guards/universal` | Language-agnostic guards |
| `hooks` | Hook scripts in `hooks/` |
| `rules` | Rule definitions in `rules/` |
| `mcp` | MCP server in `mcp-server/` |
| `scripts` | Automation scripts |
| `agents` | Agent definitions |
| `docs` | Documentation |
| `ci` | CI/CD pipeline |

**Examples:**

```
feat(guards/rust): add RS-14 check for Arc<Mutex<Option<T>>> anti-pattern

Detects unnecessary wrapping of Option inside Mutex, which often signals
a design issue. Exits with code 1 in --strict mode.

Signed-off-by: Alice <alice@example.com>
```

```
fix(hooks): prevent pre-bash-guard false positive on git stash

The guard was incorrectly flagging `git stash pop` as a dangerous
reset command. Added a more precise regex to exclude stash operations.

Signed-off-by: Bob <bob@example.com>
```

#### DCO Sign-off

Sign off automatically with:

```bash
git commit -s -m "feat(guards/go): add GO-09 goroutine count threshold check"
```

Or configure Git to always sign off:

```bash
git config --global format.signOff true
```

> **Important:** Do not add `Co-Authored-By` or any AI-generated markers to commits.

### 4. Keep Changes Focused

- One logical change per commit (atomic commits).
- A bug fix must not include unrelated refactoring.
- Style changes must be in a separate commit.

---

## Code Review Process and PR Guidelines

### Opening a PR

1. Push your branch to your fork:
   ```bash
   git push origin feat/your-feature-name
   ```

2. Open a PR against `main` on the upstream repository.

3. Use a clear title following the commit format: `feat(guards/rust): add RS-14 Arc<Mutex<Option<T>>> check`

4. Fill in the PR description with:
   - **What** — what the change does
   - **Why** — the motivation or problem it solves
   - **How to test** — steps to verify the change manually
   - **Checklist** — see below

### PR Checklist

Before requesting review, verify:

- [ ] All existing tests pass (`bash tests/test_hooks.sh`, `bash tests/test_rust_guards.sh`, `bash tests/test_setup.sh`)
- [ ] MCP server builds and tests pass (`cd mcp-server && npm run build && npm test`)
- [ ] All CI validation scripts pass (see [Running Tests](#running-tests))
- [ ] New guard scripts have corresponding regression tests in `tests/`
- [ ] New rules are referenced in `rules/` and wired to a guard (checked by `validate-wiring-contract.sh`)
- [ ] Doc paths are valid (`validate-doc-paths.sh` passes)
- [ ] Doc freshness check passes (`scripts/doc-freshness-check.sh --strict`)
- [ ] Commits are signed off (`Signed-off-by` present in every commit)
- [ ] No hardcoded secrets or credentials

### What Reviewers Look For

Reviews are prioritized in this order:

1. **Security** — No command injection, no credentials, no SSRF risks
2. **Logic** — Guard correctly identifies the target anti-pattern
3. **Quality** — Bash strict mode, proper error handling, no silent failures
4. **Performance** — Guard runs within a reasonable time on large codebases

### Review SLA

- Initial review within **5 business days**
- Address feedback and push updates to the same branch (do not force-push after review has started)
- Stale PRs (no activity for 30 days) will be closed with a note

---

## Guard Script Development Guide

Guards are the core of VibeGuard — static analysis scripts that detect anti-patterns in source code. This section explains how to write and test a new guard.

### Directory Structure

```
guards/
├── universal/          # Language-agnostic checks
├── rust/               # Rust-specific guards (RS-XX rules)
├── go/                 # Go-specific guards (GO-XX rules)
├── python/             # Python guards
└── typescript/         # TypeScript guards (TS-XX rules)
```

Each language directory contains a `common.sh` (or `common.py`) with shared utilities.

### Step 1: Define the Rule

Before writing code, document the rule in `rules/<language>.md`:

```markdown
## RS-14: Arc<Mutex<Option<T>>> Anti-Pattern (medium)
Nesting `Option` inside `Mutex` often indicates a logic issue. Use a sentinel
value or restructure ownership instead.
Fix: replace `Arc<Mutex<Option<T>>>` with `Arc<Mutex<T>>` and a sentinel value.
```

Rules follow the `<LANG>-<NN>` numbering scheme. Check existing rules to pick the next available number.

### Step 2: Write the Guard Script

Create `guards/<language>/check_<rule_slug>.sh`. All Bash guards must begin with:

```bash
#!/usr/bin/env bash
# VibeGuard <Language> Guard: <short description> (<RULE-ID>)
#
# Usage:
#   bash check_<rule_slug>.sh [target_dir]
#   bash check_<rule_slug>.sh --strict [target_dir]  # exit 1 on violations

set -euo pipefail

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
```

#### Output Format

Every finding must follow this format (consumed by downstream tools):

```
[RS-14] path/to/file.rs:42 description. Fix: remediation hint
```

Use `TMPFILE=$(create_tmpfile)` from `common.sh` to buffer output, then:

```bash
cat "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

if [[ ${FOUND} -eq 0 ]]; then
    echo "✓ No RS-14 violations found."
    exit 0
else
    echo ""
    echo "Found ${FOUND} RS-14 violation(s)."
    [[ "${STRICT:-0}" == "1" ]] && exit 1 || exit 0
fi
```

#### Exit Codes

| Code | Meaning |
|------|---------|
| `0`  | No violations (or violations found but not in `--strict` mode) |
| `1`  | Violations found in `--strict` mode |
| `2+` | Script error (misconfiguration, missing dependency) |

#### Common Utilities (`common.sh`)

| Function | Description |
|----------|-------------|
| `parse_guard_args "$@"` | Sets `TARGET_DIR` and `STRICT` variables |
| `list_rs_files <dir>` | Lists `.rs` files (prefers `git ls-files`) |
| `create_tmpfile` | Creates a temp file cleaned up on exit |

### Step 3: Wire the Guard

For guards that should run automatically, register them in the appropriate config:

- **MCP tool** — add detection logic to `mcp-server/src/tools.ts`
- **Wiring contract** — add an entry to the wiring contract validated by `scripts/ci/validate-wiring-contract.sh`
- **Language detection** — update `mcp-server/src/detector.ts` if the guard targets a new language or file pattern

### Step 4: Write Regression Tests

Add tests in `tests/test_<language>_guards.sh` (or create one if it doesn't exist). Use the helpers from the existing test files:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="${REPO_DIR}/guards/rust/check_<rule_slug>.sh"

PASS=0; FAIL=0; TOTAL=0

assert_cmd_ok()   { ... }   # expects exit 0
assert_cmd_fail() { ... }   # expects non-zero exit

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# --- Test: clean code passes ---
proj="${tmpdir}/clean"
mkdir -p "${proj}/src"
cat > "${proj}/src/lib.rs" <<'EOF'
pub fn ok() -> Option<i32> { Some(42) }
EOF
assert_cmd_ok "clean code passes" bash "${GUARD}" "${proj}"

# --- Test: violation detected in strict mode ---
proj="${tmpdir}/bad"
mkdir -p "${proj}/src"
cat > "${proj}/src/lib.rs" <<'EOF'
use std::sync::{Arc, Mutex};
fn bad() -> Arc<Mutex<Option<i32>>> { todo!() }
EOF
assert_cmd_fail "RS-14 violation caught in strict mode" bash "${GUARD}" --strict "${proj}"

printf '\nResults: %d/%d passed\n' "${PASS}" "${TOTAL}"
[[ ${FAIL} -eq 0 ]]
```

Tests must cover at minimum:

1. A clean input that should **pass** (exit 0)
2. A minimal input that should **fail** in `--strict` mode (exit 1)
3. Edge cases (e.g., test files should be excluded, comments should be ignored)

### Step 5: Validate CI Compatibility

Run the full validation suite to ensure your new guard integrates cleanly:

```bash
bash scripts/ci/validate-guards.sh
bash scripts/ci/validate-wiring-contract.sh
bash scripts/doc-freshness-check.sh --strict
```

Fix any failures before opening your PR.

### Guard Quality Checklist

- [ ] Starts with `set -euo pipefail`
- [ ] Sources `common.sh` and calls `parse_guard_args`
- [ ] Output follows `[RULE-ID] file:line description. Fix: hint` format
- [ ] Excludes test files and comment lines from detection
- [ ] Supports both warning mode (exit 0) and `--strict` mode (exit 1)
- [ ] Has regression tests for clean, violating, and edge-case inputs
- [ ] Rule is documented in `rules/<language>.md`
- [ ] Wiring is registered in the config contract

---

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). By participating, you agree to uphold this standard.

To report unacceptable behavior, open a private issue or contact the maintainers directly via the email listed in the repository.

We are committed to a welcoming, inclusive, and respectful community for everyone, regardless of experience level, background, or identity.
