# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_No unreleased changes yet. Add entries here as features are merged to `main` but before a new version tag is cut._

---

## [1.0.0] - 2026-03-14

### Added
- Pre-commit hook automation for multi-language projects (`hooks/pre-commit-guard.sh`)
- Rust `cargo fmt` check integrated into pre-commit guard (`guards/rust/`)
- Correction detection and reflection automation (`hooks/`, `scripts/`)
- Project initialization workflow for new repositories

### Fixed
- `cargo fmt` check now correctly applied in Rust pre-commit guard

---

## [0.7.0] - 2026-03-12

### Added
- Cross-platform hook runner eliminating hardcoded paths (`hooks/run-hook.sh`)
- Declaration-Execution Gap detection rule U-26 and RS-14 (`rules/claude-rules/`)
- TS-14 mock shape safety rule and strengthened U-22 coverage enforcement (`rules/claude-rules/typescript/`)
- U-25 build-failure-first rule with escalation in post-build-check (`rules/claude-rules/common/`)
- Spiral-breaker skill to interrupt runaway fix loops (`skills/`)

### Fixed
- Stop-guard exit code changed from `exit 2` to `exit 0` to prevent infinite loop (`hooks/stop-guard.sh`)
- Hardened `shasum` fallback for environments without `sha256sum`

### Changed
- Learning history updated with Declaration-Execution Gap analysis (`docs/`)

---

## [0.6.0] - 2026-03-09

### Added
- Go script guards wired into MCP `guard_check` tool (`guards/go/`, `mcp-server/`)
- Doc freshness check enforced in CI validate pipeline (`.github/workflows/`)
- MCP tests covering `compliance_report` and `metrics_collect` tools (`mcp-server/tests/`)
- Multi-language guard enforcement alignment across Go, Python, Rust, and TypeScript

### Fixed
- Rust `taste_invariants` guard wired into MCP registry and schema (`mcp-server/src/`)
- CI doc path breaks resolved; local worktree mirrors ignored in CI
- `check_semantic_effect` guard made bash3 compatible (`guards/rust/check_semantic_effect.sh`)
- Doc freshness check made deterministic without `~/.claude` rules dependency

---

## [0.5.0] - 2026-03-03

### Added
- TypeScript runtime safety guards with full wiring (`guards/typescript/`, `mcp-server/`)
- Data consistency rules (U-11 to U-14) and security rules (SEC-01 to SEC-10) (`rules/claude-rules/common/`)
- TS-13 component/hook duplication detection at pattern level (`rules/claude-rules/typescript/`)
- `core/full` profile support and system-wide path portability (`setup.sh`, `install-hook.sh`)
- Dead shim detector, doc path validator, and verifier-mode pre-commit (`guards/`)
- OpenAI Harness Engineering framework reproduced for test harness alignment (`agents/`, `workflows/`)
- Harness P1 + P2 alignment tasks completed (`tests/`, `workflows/`)
- Harness golden principles documented; reduced `console.log` false positives

### Fixed
- Session ID stabilized; subprocess overhead reduced; `install.sh` split into profiles (`scripts/`)

---

## [0.4.0] - 2026-02-27

### Added
- Anthropic official best practices integrated: Stop Gate, Interview workflow, path scope rules (`hooks/`, `skills/`)
- Mode B skill extraction from Claudeception pattern (`skills/vibeguard/SKILL.md`)
- Rust design guards hardened; MCP contract schemas tightened (`mcp-server/src/`, `guards/rust/`)
- No-alias policy enforced; plan-flow naming normalized (`rules/claude-rules/common/coding-style.md`)
- CI branch-protection gate codified for required checks (`.github/workflows/`)

### Fixed
- `pre-edit-guard` rewritten as a shell wrapper delegating core edit checks to Python (`hooks/pre-edit-guard.sh`); fixed old_string corruption from bash escaping
- Stop-guard auto-registration removed from `setup.sh` to prevent unintended installs (`setup.sh`)

### Changed
- VibeGuard workflows, guards, and hook tooling updated (`guards/`, `hooks/`, `workflows/`)
- Architecture refactored; security hardening applied; code quality improved across scripts

### Security
- Security hardening applied to MCP server and guard scripts (`mcp-server/`, `guards/`)

---

## [0.3.0] - 2026-02-18

### Added
- MCP server added (`mcp-server/`) — exposes VibeGuard guards as MCP tools
- Hooks observability: JSONL audit log and `/vibeguard:stats` command (`hooks/`, `scripts/metrics_collector.sh`)
- ECC core capabilities absorbed: 13 agents, 3 skills, security rules, enhanced hooks (`agents/`, `skills/`)
- Observability section added to `vibeguard-rules.md` (`docs/`)
- CLAUDE.md multi-level overlay mechanism documented (`README.md`)

### Fixed
- `pre-bash-guard` now strips quoted content to avoid commit message false positives (`hooks/pre-bash-guard.sh`)
- `pre-bash-guard` allows `--force-with-lease`; Protocol detection regex normalized

---

## [0.2.0] - 2026-02-15

### Added
- Hard-intercept hooks blocking issues at source (`hooks/pre-bash-guard.sh`, `hooks/pre-edit-guard.sh`)
- `guard_check` detection→fix feedback loop via PostToolUse hook (`hooks/post-guard-check.sh`)
- Preventive commands: `/vibeguard:preflight`, `/vibeguard:interview`, cross-entry consistency guards (`skills/`)
- OpenAI Harness Engineering-inspired guard system optimizations (`guards/`)
- `common.sh` extracted to eliminate duplication across guard scripts (`guards/*/common.sh`)
- MCP tool registration completed in `f444f46`

### Fixed
- `setup.sh` truncation risk resolved (`setup.sh`)
- Metrics script compatibility fixed (`scripts/metrics_collector.sh`)
- Rust guard robustness improved (`guards/rust/`)
- 12 issues from Codex review resolved across hooks and guards

### Changed
- README fully rewritten documenting three-layer defense, how it works, and onboarding (`README.md`)

---

## [0.1.0] - 2026-02-12

### Added
- Initial VibeGuard repository — AI anti-hallucination framework for Claude Code (`3719758`)
- Seven-layer defense architecture (L1–L7) defined in `spec.md`
- Rust guards RS-01 (ownership check), RS-03 (error propagation), RS-05 (unsafe audit) (`guards/rust/`)
- `auto-optimize` workflow integrated into VibeGuard (`workflows/auto-optimize/SKILL.md`)
- `setup.sh` and `install-hook.sh` for one-command installation
