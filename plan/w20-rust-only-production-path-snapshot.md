# W-20 Runtime Pinning Snapshot: Rust-only production path

- Captured at: 2026-06-05 22:28:03 CST
- Repository: `majiayu000/vibeguard`
- Branch: `main`
- Commit: `900fd570807407133c0e2cc02bd756f84c7cd0a8`
- Runtime version file: `vibeguard-runtime/VERSION` = `1.1.2`
- Installed snapshot: `~/.vibeguard/installed/version` = `a15d69a`
- Dirty state at capture: pre-existing unrelated untracked docs spec file
- Latest release tag observed: `v1.1.2`
- Release assets observed:
  - `SHA256SUMS`
  - `vibeguard-runtime-aarch64-apple-darwin`
  - `vibeguard-runtime-aarch64-unknown-linux-musl`
  - `vibeguard-runtime-x86_64-apple-darwin`
  - `vibeguard-runtime-x86_64-unknown-linux-musl`

## Tool Inventory

- `rustc 1.95.0 (59807616e 2026-04-14) (Homebrew)`
- `cargo 1.95.0 (f2d3ce0bd 2026-03-21) (Homebrew)`
- `GNU bash, version 5.3.9(1)-release (aarch64-apple-darwin25.1.0)`
- `Python 3.11.2`
- `gh version 2.86.0 (2026-01-21)`

## VibeGuard Rule Pin

- Rules directory: `rules/claude-rules`
- Rule file count: 18 markdown files
- Rule hash: `59ef8b07443f0103c85b4ad3d4f6400d37c5c47f2f9b953547268b2e09065437`
- Hash method: `guards/universal/check_runtime_drift.sh snapshot` with
  `--rules-dir rules/claude-rules`, hashing sorted per-file SHA-256 entries.

## Current Runtime Dependency Surface

`vibeguard-runtime/Cargo.toml` currently declares:

- `serde_json = "1"`
- `regex = "1"`
- `libc = "0.2"`

The Rust-only production path spec may require adding a structured TOML editing
crate and a checksum crate. Any dependency addition must be validated against
the release workflow.

## Current Python Production Surfaces

Representative surfaces captured before migration:

- Legacy Python policy helper: 229 lines
- Legacy Python apply-patch adapter helper: 170 lines
- `scripts/lib/settings_json.py`: 594 lines
- `scripts/lib/codex_hooks_json.py`: 524 lines
- `scripts/lib/codex_config_toml.py`: 205 lines
- `scripts/lib/vibeguard_manifest.py`: 724 lines
- `scripts/lib/claude_md.py`: 148 lines
- `scripts/lib/project_config_validate.py`: 163 lines
- `scripts/lib/install-state.sh`: 235 lines
- `hooks/pre-edit-guard.sh`: 275 lines
- `hooks/_lib/codex_runner.sh`: 203 lines

## Scope Boundaries

- In scope: supported release-target install/check/clean and configured
  first-party Claude/Codex hook execution.
- Out of scope: eval, benchmarks, docs generation, CI-only scripts, optional
  language guard packs, and full repository Rust rewrite.

## Stop Conditions

- A high-context file write cannot preserve existing dry-run diff and explicit
  confirmation behavior.
- Rust policy/config behavior would intentionally diverge from existing wrapper
  behavior.
- A Python fallback would be removed before equivalent Rust regression coverage
  exists.
- New runtime dependencies break release target builds or checksum publishing.
