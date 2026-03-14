# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_No unreleased changes yet. Add entries here as features are merged to `main` but before a new version tag is cut._

---

## [1.0.0] - 2026-03-14

### Added
- Pre-commit hook automation for multi-language projects (`hooks/pre-commit`)
- Rust `cargo fmt` check integrated into pre-commit guard (`guards/rust/`)
- Correction detection and reflection automation (`hooks/`, `scripts/`)
- Project initialization workflow for new repositories

### Fixed
- `cargo fmt` check now correctly applied in Rust pre-commit guard

---

## [0.7.0] - 2026-03-12

### Added
- Cross-platform hook wrapper eliminating hardcoded paths (`hooks/wrapper.sh`)
- Declaration-Execution Gap detection rule U-26 and RS-14 (`rules/vibeguard/`)
- TS-14 mock shape safety rule and strengthened U-22 coverage enforcement (`rules/vibeguard/ts/`)
- U-25 build-failure-first rule with escalation in post-build-check (`rules/vibeguard/common/`)
- Spiral-breaker skill to interrupt runaway fix loops (`skills/`)

### Fixed
- Stop-guard exit code changed from `exit 2` to `exit 0` to prevent infinite loop (`hooks/stop-guard`)
- Hardened `shasum` fallback for environments without `sha256sum`

### Changed
- Learning history updated with Declaration-Execution Gap analysis (`docs/learning-history.md`)

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
- `semantic_effect` guard made bash3 compatible (`guards/rust/semantic_effect.sh`)
- Doc freshness check made deterministic without `~/.claude` rules dependency

---

## [0.5.0] - 2026-03-02

### Added
- Rust workspace with 10 crates and 30 unit tests (closes #3) (`mcp-server/src/`)
- TypeScript runtime safety guards with full wiring (`guards/ts/`, `mcp-server/`)
- Data consistency rules (U-11 to U-14) and security rules (SEC-01 to SEC-10) (`rules/vibeguard/common/`)
- TS-13 component/hook duplication detection at pattern level (`rules/vibeguard/ts/`)
- `core/full` profile support and system-wide path portability (`setup.sh`, `install-hook.sh`)
- Dead shim detector, doc path validator, and verifier-mode pre-commit (`guards/`)
- OpenAI Harness Engineering framework reproduced for test harness alignment (`agents/`, `workflows/`)
- Harness P1 + P2 alignment tasks completed (`tests/`, `workflows/`)
- Harness golden principles documented; reduced `console.log` false positives

### Fixed
- Builtin rule loading implemented via `include_str!` macro (closes #2) (`mcp-server/src/`)
- Session ID stabilized; subprocess overhead reduced; `install.sh` split into profiles (`scripts/`)

---

## [0.4.0] - 2026-02-27

### Added
- Anthropic official best practices integrated: Stop Gate, Interview workflow, path scope rules (`hooks/`, `skills/`)
- Mode B skill extraction from Claudeception pattern (`skills/vibeguard/learn.md`)
- Rust design guards hardened; MCP contract schemas tightened (`mcp-server/src/`, `guards/rust/`)
- No-alias policy enforced; plan-flow naming normalized (`rules/vibeguard/common/coding-style.md`)
- CI branch-protection gate codified for required checks (`.github/workflows/`)

### Fixed
- `pre-edit-guard` fully rewritten in Python; fixed old_string corruption from bash escaping (`hooks/pre-edit-guard.py`)
- Stop-guard auto-registration removed from `setup.sh` to prevent unintended installs (`setup.sh`)

### Changed
- VibeGuard workflows, guards, and hook tooling updated (`guards/`, `hooks/`, `workflows/`)
- Architecture refactored; security hardening applied; code quality improved across scripts

### Security
- Security hardening applied to MCP server and guard scripts (`mcp-server/`, `guards/`)

---

## [0.3.0] - 2026-02-17

### Added
- MCP server added (`mcp-server/`) — exposes VibeGuard guards as MCP tools
- Hooks observability: JSONL audit log and `/vibeguard:stats` command (`hooks/`, `scripts/metrics.sh`)
- ECC core capabilities absorbed: 13 agents, 3 skills, security rules, enhanced hooks (`agents/`, `skills/`)
- Observability section added to `vibeguard-rules.md` (`docs/`)
- CLAUDE.md multi-level overlay mechanism documented (`README.md`)

### Fixed
- `pre-bash-guard` now strips quoted content to avoid commit message false positives (`hooks/pre-bash-guard`)
- `pre-bash-guard` allows `--force-with-lease`; Protocol detection regex normalized

---

## [0.2.0] - 2026-02-15

### Added
- Hard-intercept hooks blocking issues at source (`hooks/pre-bash-guard`, `hooks/pre-edit-guard`)
- `guard_check` detection→fix feedback loop via PostToolUse hook (`hooks/post-tool-use`)
- Preventive commands: `/vibeguard:preflight`, `/vibeguard:interview`, cross-entry consistency guards (`skills/`)
- OpenAI Harness Engineering-inspired guard system optimizations (`guards/`)
- `common.sh` extracted to eliminate duplication across guard scripts (`guards/common.sh`)
- MCP tool registration completed in `f444f46`

### Fixed
- `setup.sh` truncation risk resolved (`setup.sh`)
- Metrics script compatibility fixed (`scripts/metrics.sh`)
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
- `auto-optimize` workflow integrated into VibeGuard (`workflows/auto-optimize.md`)
- `setup.sh` and `install-hook.sh` for one-command installation

[Unreleased]: https://github.com/majiayu000/vibeguard/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/majiayu000/vibeguard/compare/v0.7.0...v1.0.0
[0.7.0]: https://github.com/majiayu000/vibeguard/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/majiayu000/vibeguard/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/majiayu000/vibeguard/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/majiayu000/vibeguard/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/majiayu000/vibeguard/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/majiayu000/vibeguard/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/majiayu000/vibeguard/releases/tag/v0.1.0
