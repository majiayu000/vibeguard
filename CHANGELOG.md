# Changelog

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
