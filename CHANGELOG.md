# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- CI doc command path validator (`scripts/ci/validate-doc-command-paths.sh`) to catch stale `~/vibeguard/...` shell examples

### Fixed
- `check_code_slop.sh` output wording aligned with unit tests (`Legacy debug code`)
- `tests/unit/run_all.sh` now strips ANSI escape codes before parsing assertion counts
- Documentation command examples updated to current script layout (`scripts/metrics/` and `scripts/verify/`)
- `doc-freshness-check.sh` now uses `rules/claude-rules/` as canonical rule source and deduplicates guard file reporting
- Added missing `PY-13` rule definition in Claude-native Python rule set

### Changed
- `check_code_slop.sh` supports `--include-fixtures` and `--strict-repo` scanning modes
- `check_code_slop.sh` now excludes repository-local noise directories by default (`.claude`, `.vibeguard`, `.omx`, `tests/fixtures`)
- `check_code_slop.sh` TODO stale-date scan limit is configurable via `VIBEGUARD_TODO_SCAN_LIMIT` (default 20)

## [1.1.0] - 2026-04-02

### Added
- Codex CLI hooks support: 4 hooks deployed via `~/.codex/hooks.json` with output format adapter (`hooks/run-hook-codex.sh`)
- Guard message v2 format: OBSERVATION/FIX/DO NOT structure (`guards/`)
- Baseline scanning: only report issues on newly added lines (`guards/`)
- Test infrastructure protection rule W-12 (`guards/`)
- `updatedInput` transparent package manager correction (`hooks/`)
- Hook circuit breaker for runaway failures (`hooks/circuit-breaker.sh`)
- AST-grep precision guards with YAML rule definitions (`guards/ast-grep-rules/`)
- Prepublish tarball verification (`scripts/verify/verify-package-contents.sh`)
- Platform bug tracking for known Claude Code issues (`docs/known-issues/`)

### Fixed
- Session ID scoped to project directory, prevents cross-project pollution (`hooks/log.sh`)
- 9 known false positive patterns resolved (`guards/`)
- Suppression regex tightened; staged content used in pre-commit mode (`guards/`)
- GO-01 multi-discard miss and TS-03 path-contamination false negatives (`guards/`)
- Compliance check YAML array detection and single-quote paths (`scripts/verify/`)
- Metrics exporter Prometheus label newline stripping (`scripts/metrics/`)
- Skills-loader disabled by default to reduce startup overhead (`hooks/`)
- CI cross-platform Windows compatibility with `defaults shell:bash`

### Changed
- Setup targets split by platform (`scripts/setup/targets/`)
- Root directory reorganized: removed 4 single-file directories, grouped scripts into `gc/`, `metrics/`, `verify/` subdirectories
- Removed unused MCP server, replaced with direct guard scripts
- Removed: `package.json`, `Dockerfile`, `blueprints/`, `mcp-server/`, `index.js`, `index.ts`
- `README_CN.md` moved to `docs/`
- Runtime hooks isolated from dev repo via installed snapshot

---

## [1.0.0] - 2026-03-14

### Added
- Pre-commit hook automation for multi-language projects (`hooks/pre-commit-guard.sh`)
- Rust `cargo fmt` check integrated into pre-commit guard (`guards/rust/`)
- Correction detection and reflection automation (`hooks/learn-evaluator.sh`)
- Project initialization workflow for new repositories

### Fixed
- `cargo fmt` check now correctly invoked in Rust pre-commit guard (`hooks/pre-commit-guard.sh`)

---

## [0.8.0] - 2026-03-13

### Added
- Correction detection logic — tracks AI correction events for pattern learning (`hooks/learn-evaluator.sh`)
- Reflection automation — triggers reflection after detected corrections (`hooks/post-guard-check.sh`)
- Project init script for bootstrapping new repos with VibeGuard defaults

---

## [0.7.0] - 2026-03-12

### Added
- Cross-platform hook wrapper eliminating hardcoded paths (`hooks/pre-bash-guard.sh`, `hooks/pre-edit-guard.sh`)
- Declaration-Execution Gap detection rule U-26 and guard RS-14 (`guards/rust/check_declaration_execution_gap.sh`)
- TS-14 mock shape safety rule added to TypeScript guard set (`guards/typescript/`)
- U-25 build-failure-first rule with escalation path in post-build-check (`hooks/post-build-check.sh`)
- Spiral-breaker skill to interrupt runaway fix loops (`.claude/commands/vibeguard/`)
- Stop hook exit 2 infinite loop issue documented (`docs/reference/claude-code-known-issues.md`)

### Fixed
- Stop-guard exit code changed from `exit 2` to `exit 0` to prevent infinite hook loop (`hooks/`)
- Hardened `shasum` fallback for environments without `sha256sum` (`hooks/pre-commit-guard.sh`)

### Changed
- Learning history updated with Declaration-Execution Gap analysis (`docs/`)
- U-22 coverage enforcement strengthened to require 100% on critical paths

---

## [0.6.0] - 2026-03-09

### Added
- Go script guards wired into MCP `guard_check` tool (`guards/go/`, `mcp-server/src/`)
- Doc freshness check enforced in CI validate pipeline (`.github/workflows/ci.yml`)
- MCP tests covering `compliance_report` and `metrics_collect` tools (`mcp-server/tests/`)
- Multi-language guard enforcement alignment across Go, Python, Rust, and TypeScript (`guards/`)
- Harness golden principles documented; reduced `console.log` false positives (`guards/typescript/check_console_residual.sh`)

### Fixed
- Rust `taste_invariants` guard wired into MCP registry and schema (`mcp-server/src/`, `guards/rust/check_taste_invariants.sh`)
- CI doc path breaks resolved; local worktree mirrors ignored in CI (`.github/workflows/ci.yml`)
- `semantic_effect` guard made bash3 compatible (`guards/rust/check_semantic_effect.sh`)
- Doc freshness check made deterministic without `~/.claude` rules dependency (`.github/workflows/ci.yml`)

---

## [0.5.0] - 2026-03-02

### Added
- Rust workspace with 10 crates and 30 unit tests, closes #3 (`mcp-server/src/`)
- TypeScript runtime safety guards with full MCP wiring (`guards/typescript/`, `mcp-server/src/`)
- Data consistency rules U-11 through U-14 (`guards/universal/`, `claude-md/vibeguard-rules.md`)
- Security rules SEC-01 through SEC-10 (`guards/universal/`, `claude-md/vibeguard-rules.md`)
- TS-13 component and hook duplication detection at pattern level (`guards/typescript/check_component_duplication.sh`)
- `core/full` profile support and system-wide path portability (`setup.sh`)
- Dead shim detector (`guards/python/check_dead_shims.py`)
- Doc path validator and verifier-mode pre-commit hook (`guards/python/`)
- OpenAI Harness Engineering framework reproduced for test harness alignment (`agents/`, `blueprints/`)
- Harness P1 and P2 alignment tasks completed (`mcp-server/tests/`, `hooks/`)
- Go guards: defer-in-loop, error handling, and goroutine leak checks (`guards/go/`)
- Universal guards: circular dependency and dependency layer checks (`guards/universal/`)

### Fixed
- Builtin rule loading implemented with `include_str!` macro, closes #2 (`mcp-server/src/`)
- Session ID stabilized; subprocess overhead reduced (`hooks/`)
- `install.sh` split into core and full profiles (`setup.sh`)

---

## [0.4.0] - 2026-02-27

### Added
- Anthropic official best practices integrated: Stop Gate, Interview workflow, path scope rules (`hooks/`, `.claude/commands/vibeguard/`)
- Mode B skill extraction from Claudeception pattern (`.claude/commands/vibeguard/learn.md`)
- Rust design guards hardened; MCP contract schemas tightened (`mcp-server/src/`, `guards/rust/`)
- No-alias policy (U-24) enforced; plan-flow naming normalized (`guards/universal/`, `claude-md/vibeguard-rules.md`)
- CI branch-protection gate codified for required checks (`.github/workflows/ci.yml`)

### Fixed
- `pre-edit-guard` fully rewritten in Python; fixed old_string corruption from bash escaping (`hooks/pre-edit-guard.sh`)
- Stop-guard auto-registration removed from `setup.sh` to prevent unintended installs

### Changed
- VibeGuard workflows, guards, and hook tooling updated across the board
- Architecture refactored with security hardening applied

### Security
- Security hardening applied to MCP server and guard scripts (`mcp-server/`, `guards/`)

---

## [0.3.0] - 2026-02-17

### Added
- MCP server (`mcp-server/`) — exposes VibeGuard guards as MCP tools callable from Claude Code
- Hooks observability: JSONL audit log (`hooks/log.sh`) and `/vibeguard:stats` statistics command
- ECC core capabilities absorbed: 13 specialist agents (`agents/`), 3 skills, security rules, enhanced hooks
- Observability section added to `claude-md/vibeguard-rules.md`
- CLAUDE.md multi-level overlay mechanism documented in `README.md`
- Context profiles for dev, research, and review workflows (`context-profiles/`)

### Fixed
- `pre-bash-guard` now strips quoted content to avoid commit message false positives (`hooks/pre-bash-guard.sh`)
- `pre-bash-guard` allows `--force-with-lease`; Protocol detection regex normalized

---

## [0.2.0] - 2026-02-15

### Added
- Hard-intercept hooks blocking dangerous operations at source (`hooks/pre-bash-guard.sh`, `hooks/pre-edit-guard.sh`)
- `guard_check` detection→fix feedback loop via PostToolUse hook (`hooks/post-guard-check.sh`)
- Preventive commands: `/vibeguard:preflight`, `/vibeguard:interview`, `/vibeguard:review` (`.claude/commands/vibeguard/`)
- Cross-entry data consistency guards (`guards/universal/check_dependency_layers.py`)
- OpenAI Harness Engineering-inspired guard system optimizations (`guards/`)
- `common.sh` extracted to eliminate duplication across guard scripts (`guards/rust/common.sh`, `guards/go/common.sh`, `guards/typescript/common.sh`)
- MCP tool registration completed for all guard categories
- Blueprints for pre-commit and standard edit patterns (`blueprints/`)

### Fixed
- `setup.sh` truncation risk resolved
- Metrics script compatibility fixed (`hooks/log.sh`)
- Rust guard robustness improved (`guards/rust/`)
- 12 issues from Codex review resolved across hooks and guards

### Changed
- README fully rewritten documenting three-layer defense, how it works, and onboarding (`README.md`)

---

## [0.1.0] - 2026-02-12

### Added
- Initial VibeGuard repository — AI anti-hallucination framework for Claude Code
- Seven-layer defense architecture (L1–L7) defined in `claude-md/vibeguard-rules.md`
- Rust guards RS-01 (unwrap in prod), RS-03 (duplicate types), RS-05 (single source of truth) (`guards/rust/`)
- `auto-optimize` workflow integrated into VibeGuard
- `setup.sh` and install scripts for one-command installation

[Unreleased]: https://github.com/majiayu000/vibeguard/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/majiayu000/vibeguard/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/majiayu000/vibeguard/compare/v0.8.0...v1.0.0
[0.8.0]: https://github.com/majiayu000/vibeguard/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/majiayu000/vibeguard/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/majiayu000/vibeguard/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/majiayu000/vibeguard/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/majiayu000/vibeguard/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/majiayu000/vibeguard/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/majiayu000/vibeguard/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/majiayu000/vibeguard/releases/tag/v0.1.0
