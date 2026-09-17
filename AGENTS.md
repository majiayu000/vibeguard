# Agent instructions

VibeGuard v2 is a Rust CLI with a curated rule library and native integrations. This file applies to the repository.

- Check `git status --short --branch` and preserve unrelated work. Search before adding code or files.
- Read [the directory map](docs/directory-map.md) before moving public paths and [the runtime contract](docs/runtime-contract.md) before changing hooks or installation.
- Keep the runtime in Rust. The optional plugin is a help entry point, not another runtime.
- Keep one writable session per worktree. Use read-only helpers for independent tasks when delegation is authorized.
- Follow the user's scope and existing authorization. Inspection alone does not authorize mutation.
- No compatibility shims, old ID aliases, workflow engines, or semantic regex scanners without an explicit new requirement.
- Keep errors visible; unavailable evidence is not success. Preserve valid tests and user-managed instructions/settings.
- Changes to installation, instructions, permissions, and release behavior require explicit task intent.
- Use snake_case internally; native protocol fields retain host spelling.
- Use host-native execution and permissions. Do not add an agent-loop proxy.
- Do not install globally, publish, push, merge, or send messages without authorization.
- Major architecture needs a concise plan, at most two files and about 300 lines. Ordinary work needs no process packet.
- Review at most twice. Stop after relevant checks pass and no findings remain.

## Validation

From the repository root:

| Change | Focused verification |
|---|---|
| Rust | `cargo check --locked --manifest-path vibeguard-runtime/Cargo.toml` and `cargo test --locked --manifest-path vibeguard-runtime/Cargo.toml` |
| Rules | `python3 scripts/generate_rule_docs.py` then `bash scripts/ci/validate-rules.sh` |
| Docs | `bash scripts/ci/validate-doc-paths.sh` and `bash scripts/ci/validate-doc-command-paths.sh` |
| Python tooling | `python3 -m unittest discover -s tests -p 'test_*.py'` |
| Multiple surfaces / submission | `bash scripts/local-contract-check.sh` |

The broad gate runs formatting, Clippy, Cargo check/tests, rule generation, Python tests, docs checks, and a release-binary smoke test. Platform CI runs Rust checks on Linux, macOS, and Windows. Windows native installation must fail clearly until implemented.

[Plans](plan/README.md) record decisions; they are not an automatic backlog. Report actual checks and limitations.
