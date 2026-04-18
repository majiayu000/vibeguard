# Contributing to VibeGuard

Thank you for contributing to VibeGuard, the AI anti-hallucination guard system for Claude Code and Codex. This guide covers setup, validation, review expectations, and the repository's commit protocol.

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
| Git | 2.30+ | Version control |
| Bash | 5.0+ | Hook and guard scripts |
| Python | 3.11+ | Analysis scripts |
| Node.js | 20+ | CI parity for docs / Codex integration checks |

> **macOS users:** the system Bash (3.x) is too old. Install a modern Bash with `brew install bash`.

### Clone and Install

```bash
# 1. Fork the repository on GitHub, then clone your fork
git clone https://github.com/<your-username>/vibeguard.git
cd vibeguard

# 2. Add the upstream remote
git remote add upstream https://github.com/majiayu000/vibeguard.git

# 3. Run the setup script (installs VibeGuard into ~/.claude/ and ~/.codex/)
bash setup.sh
```

### Running Validation and Tests

All relevant validation and regression suites should pass before you open a PR.

```bash
# Core regression tests
bash tests/test_hooks.sh
bash tests/test_rust_guards.sh
bash tests/test_setup.sh
bash tests/test_hook_health.sh

# Focused unit / precision coverage
bash tests/unit/run_all.sh
bash tests/test_precision_tracker.sh
bash tests/run_precision.sh --all --csv

# CI validation scripts
bash scripts/ci/validate-guards.sh
bash scripts/ci/validate-hooks.sh
bash scripts/ci/validate-rules.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
bash scripts/verify/doc-freshness-check.sh --strict
```

If your change touches installation, Codex hook wiring, or repo docs, prefer running the full set above. The authoritative source for CI coverage is [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

### Local Contract Gate

A dedicated wrapper runs the stable, fast subset of contract checks in one command — the same checks available in CI but scoped to what is deterministic, repository-local, and cheap enough for a commit loop.

```bash
# Run the full local gate manually
bash scripts/local-contract-check.sh

# Skip the doc-freshness check for a faster pass
bash scripts/local-contract-check.sh --quick

# Wire the gate as a git pre-commit hook (one-time setup)
bash scripts/install-pre-commit-hook.sh
```

**Local-vs-CI split**

| Check | Local gate | CI only |
|-------|-----------|---------|
| `validate-guards.sh` | Yes | Yes |
| `validate-hooks.sh` | Yes | Yes |
| `validate-rules.sh` | Yes | Yes |
| `validate-doc-paths.sh` | Yes | Yes |
| `validate-doc-command-paths.sh` | Yes | Yes |
| `doc-freshness-check.sh --strict` | Yes (skippable with `--quick`) | Yes |
| `test_manifest_contract.sh` | Yes (once PR #80 merges) | Yes |
| `test_eval_contract.sh` | Yes (once PR #80 merges) | Yes |
| Benchmark suite (`bench_hook_latency.sh`) | No — too slow | Yes |
| Full precision suite (`run_precision.sh --all`) | No — requires full dataset | Yes |
| Hook regression matrix (`test_hooks.sh`) | No — run manually | Yes |
| Static perf analysis | No | Yes |

> **Note:** The local gate is Unix-first (Linux and macOS). Windows contributors should run the full CI matrix for contract coverage, as several checks depend on Bash 5+ features not available in Git Bash or WSL by default.

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

Keep branch names lowercase, hyphenated, and short enough to stay readable.

### 2.1 Rule and documentation sync requirements

When changing rules, guards, hooks, or script paths, update matching docs in the same PR:

- Rule changes: keep `rules/claude-rules/**`, `rules/*.md`, and `docs/rule-reference.md` aligned.
- Script moves or renames: update command examples in `README.md`, `docs/README_CN.md`, and any contributor docs that mention them.
- Documentation checks: run both `bash scripts/ci/validate-doc-paths.sh` and `bash scripts/ci/validate-doc-command-paths.sh`.
- Coverage checks: run `bash scripts/verify/doc-freshness-check.sh --strict` after changing guards or rule IDs.

### 3. Commit Message Format

This repository uses the **Lore Commit Protocol**. The first line must explain **why** the change exists, not merely what changed. Follow it with short narrative context and git-native trailers.

```text
<intent line: why the change was made>

<body: context, constraints, and approach>

Constraint: <external constraint that shaped the decision>
Rejected: <alternative considered> | <reason it was rejected>
Confidence: <low|medium|high>
Scope-risk: <narrow|moderate|broad>
Reversibility: <clean|messy|irreversible>
Directive: <warning or instruction for future modifiers>
Tested: <what you verified>
Not-tested: <known verification gap>
```

Example:

```text
Keep public docs aligned with the shipped setup flow

Refresh README, Chinese docs, and contributor guidance so users stop
copying commands for runtime knobs and CI scripts that do not exist.

Constraint: Docs must match files that exist in the repo today
Rejected: Leave docs broad and aspirational | users would copy broken commands
Confidence: high
Scope-risk: narrow
Reversibility: clean
Directive: When adding or renaming scripts, update README.md, docs/README_CN.md, and CONTRIBUTING.md in the same PR
Tested: bash scripts/ci/validate-doc-paths.sh; bash scripts/ci/validate-doc-command-paths.sh
Not-tested: Fresh install on a clean machine
```

Optional trailers such as `Related:` are encouraged when they add useful context. Do not add AI markers or `Co-Authored-By` lines unless explicitly requested by a maintainer.

### 4. Keep Changes Focused

- One logical change per commit.
- A bug fix must not include unrelated refactoring.
- Style-only edits belong in a separate commit.
- Prefer deletion and reuse over new abstraction layers.

---

## Code Review Process and PR Guidelines

### Opening a PR

1. Push your branch to your fork:
   ```bash
   git push origin feat/your-feature-name
   ```
2. Open a PR against `main` on the upstream repository.
3. Use a clear, specific PR title. A short conventional-style summary is fine for the PR even though commit bodies use Lore protocol.
4. Fill in the PR description with:
   - **What** — what changed
   - **Why** — the problem or risk it addresses
   - **How to test** — commands or steps to verify it
   - **Checklist** — see below

### PR Checklist

Before requesting review, verify:

- [ ] All relevant regression tests pass (`bash tests/test_hooks.sh`, `bash tests/test_rust_guards.sh`, `bash tests/test_setup.sh`, `bash tests/test_hook_health.sh`)
- [ ] Scope-appropriate unit tests pass (`bash tests/unit/run_all.sh` for guard-heavy changes)
- [ ] Precision / scoring checks were run when the change affects detection quality (`bash tests/run_precision.sh --all --csv`, `bash tests/test_precision_tracker.sh`)
- [ ] All CI validation scripts pass (see [Running Validation and Tests](#running-validation-and-tests))
- [ ] New guard scripts have regression coverage in `tests/unit/` and, when appropriate, higher-level suites in `tests/`
- [ ] New or changed rules are reflected in `rules/*.md`, `rules/claude-rules/**`, and `docs/rule-reference.md`
- [ ] Doc freshness passes (`bash scripts/verify/doc-freshness-check.sh --strict`)
- [ ] Doc paths and shell command paths are valid (`validate-doc-paths.sh` and `validate-doc-command-paths.sh`)
- [ ] Commits use the Lore protocol trailers
- [ ] No hardcoded secrets or credentials were introduced

### What Reviewers Look For

Reviews are prioritized in this order:

1. **Security** — no command injection, no credentials, no SSRF risks
2. **Logic** — the guard or hook actually identifies the intended anti-pattern
3. **Quality** — Bash strict mode, clear failure modes, no silent degradation
4. **Performance** — the checks stay reasonable on large repositories
5. **Documentation** — user-facing commands, filenames, and workflow descriptions match the code

### Review SLA

- Initial review within **5 business days**
- Address feedback and push updates to the same branch
- Do not force-push after review has started unless a maintainer asks for it
- Stale PRs (no activity for 30 days) may be closed with a note

---

## Guard Script Development Guide

Guards are the core of VibeGuard. They are static analysis scripts that detect anti-patterns in source code and feed findings back into the higher-level workflow.

### Directory Structure

```text
guards/
├── universal/          # Language-agnostic checks
├── rust/               # Rust-specific guards (RS-XX rules)
├── go/                 # Go-specific guards (GO-XX rules)
├── python/             # Python guards
└── typescript/         # TypeScript guards (TS-XX rules)
```

Bash-based language directories (`rust/`, `go/`, `typescript/`) each contain a `common.sh` with shared utilities. Python guards are standalone scripts.

### Step 1: Define the rule

Document the rule in `rules/<language>.md` first. If the rule should also shape Claude Code's reasoning layer, add or update the corresponding native-rule entry under `rules/claude-rules/**`.

```markdown
## RS-14: Arc<Mutex<Option<T>>> anti-pattern (medium)
Nesting `Option` inside `Mutex` often indicates a logic issue. Use a sentinel
value or restructure ownership instead.
Fix: replace `Arc<Mutex<Option<T>>>` with `Arc<Mutex<T>>` and a sentinel value.
```

Rules follow the `<LANG>-<NN>` numbering scheme. Check existing rules before picking a new ID.

### Step 2: Write the guard script

The file format differs by language:

**Bash guards (Rust, Go, TypeScript)** — create `guards/<language>/check_<rule_slug>.sh` and start with:

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

**Python guards** — create `guards/python/check_<rule_slug>.py` and parse arguments directly from `sys.argv`:

```python
#!/usr/bin/env python3
"""<Short description> (<RULE-ID>).

Usage:
    python3 check_<rule_slug>.py [target_dir]
    python3 check_<rule_slug>.py [target_dir] --strict
"""

import sys
from pathlib import Path


def main() -> int:
    strict = "--strict" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    target_dir = Path(args[0]) if args else Path(".")
    # ... detection logic ...
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

#### Output format

Every finding must follow this format because downstream tools consume it:

```text
[RS-14] path/to/file.rs:42 description. Fix: remediation hint
```

Use `TMPFILE=$(create_tmpfile)` from `common.sh` to buffer output in Bash guards. Print a clear summary and return `1` only when violations are present in `--strict` mode.

#### Exit codes

| Code | Meaning |
|------|---------|
| `0` | No violations, or violations found outside `--strict` mode |
| `1` | Violations found in `--strict` mode |
| `2+` | Script error (misconfiguration, dependency missing, etc.) |

### Step 3: Wire the guard

For guards that should be visible outside a single script file, update all relevant surfaces:

- `docs/rule-reference.md` — document the new guard and the rule it enforces
- `README.md` / `docs/README_CN.md` — update command examples if the new guard is part of the user-facing surface
- Hook or setup wiring — if the guard should run automatically, update the appropriate hook, installer, or validator
- Tests — extend the matching regression and unit suites

At minimum, run `bash scripts/ci/validate-guards.sh` and `bash scripts/verify/doc-freshness-check.sh --strict` after wiring a new rule/guard pair.

### Step 4: Write regression tests

Prefer focused tests under `tests/unit/` for individual guards. Add or update higher-level suites in `tests/` when the change affects hook orchestration, setup flow, or end-to-end behavior.

Tests should cover at minimum:

1. A clean input that should pass
2. A minimal violating input that should fail in `--strict` mode
3. Important edge cases (tests, comments, generated files, or language-specific false-positive traps)

### Step 5: Validate CI compatibility

Run the smallest complete verification set for your change:

- Guard-only change: `validate-guards.sh`, `validate-rules.sh`, `tests/unit/run_all.sh`, `doc-freshness-check.sh --strict`
- Hook change: add `validate-hooks.sh`, `tests/test_hooks.sh`, `tests/test_hook_health.sh`
- Setup / Codex integration change: add `tests/test_setup.sh`
- Documentation or path change: add `validate-doc-paths.sh` and `validate-doc-command-paths.sh`

If the change affects detection quality or scoring, also run `bash tests/run_precision.sh --all --csv` and `bash tests/test_precision_tracker.sh`.

### Guard Quality Checklist

- [ ] Starts with strict error handling (`set -euo pipefail` for Bash)
- [ ] Uses shared helpers where they already exist (`common.sh`, temp-file helpers, guard-path helpers)
- [ ] Output follows `[RULE-ID] file:line description. Fix: hint`
- [ ] Handles expected exclusions and avoids obvious false positives
- [ ] Supports `--strict` mode correctly
- [ ] Has scope-appropriate regression coverage
- [ ] Rule docs and user-facing docs stay in sync with the implementation

---

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). By participating, you agree to uphold this standard.

To report unacceptable behavior, open an issue on the [GitHub issue tracker](https://github.com/majiayu000/vibeguard/issues) with the label `conduct`. If the matter is sensitive and you prefer not to post publicly, contact the repository maintainer through their GitHub profile at [github.com/majiayu000](https://github.com/majiayu000).
