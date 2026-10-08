# Changelog

## 2.1.0 — Unreleased

- Preview installation with `install --dry-run` before writing host or Git integration files; preserve user-owned configuration and report disabled hooks.
- Integrate #831–#834: original local Git-object inspection, Bash command/redirection/heredoc boundaries, rule/build/evaluation checks, and concurrent setup protection with bounded legacy inventory.
- Keep host observations and model-effect evidence separate from installation completeness; no task-verification or broad productivity claim.

## 2.0.2 — 2026-10-07

- Add `hook dsh` for Bash policy checks and structured result observations with explicit DSH host attribution.
- Add the optional `@vibeguard-ai/dsh` 0.1.0 adapter for published DeepSeek Harness 0.2.0-rc.2: native approval for policy blocks, hard denial for pre-call runtime failures, and preserved completed results on observation failure.
- Include bilingual source/install instructions and real DSH lifecycle and approval integration checks.

## 2.0.1 — 2026-09-25

- Fix a panic in `status`, `install`, and `uninstall` when an instruction file contains a line beginning with a multibyte Unicode character.

## 2.0.0 — 2026-09-19

- Rust CLI with native Bash hooks, explicit Git pre-push protection, six compact principles, and 75 scoped rule topics derived from all 125 earlier IDs.
- Direct rule lookup, native deny responses, real Git ancestry checks, managed installation/uninstallation, and minimal local diagnostics.
- Regression coverage for generated hook execution, preserved content, corruption, executable permission repair, and release binaries.
- Removed app-server wrapper, package rewriting, language grep scanners, Stop counters and keyword verification, profiles, policy configuration, learning/scoring telemetry, workflow routing, and duplicate distribution layers.
- No old commands, ID aliases, or data migration.
- Native install supports macOS, Linux, WSL. Windows CLI/protocol remains tested in CI; native install explicitly errors.
- Status reports local facts and observations without host-trust, full-coverage, or task-verification guarantees.

Use the old version's uninstall procedure before installing v2. The v2 installer does not interpret or delete v1 assets. Earlier history remains in Git.
