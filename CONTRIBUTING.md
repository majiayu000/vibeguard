# Contributing

Favor a small Rust implementation, scoped rule text, and observable behavior. Explain a reproducible problem before proposing a new subsystem.

```bash
cargo check --locked --manifest-path vibeguard-runtime/Cargo.toml
cargo test --locked --manifest-path vibeguard-runtime/Cargo.toml
bash scripts/local-contract-check.sh
```

Edit canonical Markdown in `rules/claude-rules/`, then run `python3 scripts/generate_rule_docs.py`. Do not hand-edit generated outputs. A rule explains when it applies, the desired behavior, and material exceptions. Do not reuse an ID for a different meaning.

Blocking checks need real positive and negative examples, precise coverage, and a reason professional tools cannot enforce them better. Use task outcomes for [model evaluation](eval/README.md), not the model's own score.

Installer tests use temporary homes and repositories. Preserve user content, permissions, and visible errors. Describe concrete changes and actual verification in the PR; document removed capabilities. Review at most twice.

The source launcher and local smoke gate use the executable selected by Cargo, including a configured `CARGO_TARGET_DIR` or `build.target-dir`. The smoke gate reads the build's artifact messages rather than guessing a path to an earlier binary.

CI and release verification also run the reusable dependency-policy workflow against the locked Rust graph and `deny.toml`, including advisories, licenses, duplicate versions, and dependency sources. This online check is separate from the local contract gate; unavailable advisory data is a failed check. To run it locally with cargo-deny 0.20.2 installed, use `cargo deny --manifest-path vibeguard-runtime/Cargo.toml --locked --all-features --config deny.toml check`.

Release publishing is a separate maintainer action. Tagged releases verify the version, build and smoke native binaries, and package only the executable, README, and license. Review the source before creating a tag.

See [AGENTS.md](AGENTS.md), [directory map](docs/directory-map.md), and [security policy](SECURITY.md).
