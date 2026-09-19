# Directory map

| Path | Ownership |
|---|---|
| `vibeguard-runtime/src/` | Rust CLI, native protocol, Bash/Git checks, observations, installer |
| `vibeguard-runtime/tests/` | Executable regression tests with temporary homes/repositories |
| `rules/claude-rules/` | Canonical rule text for both hosts; the path does not imply a Claude dependency |
| `rules/rule-descriptions.json` | Generated catalog embedded at compile time |
| `claude-md/vibeguard-rules.md` | Generated compact core embedded at compile time |
| `scripts/generate_rule_docs.py` | Sole rule generator |
| `scripts/ci/` | Current rule, documentation, and binary checks |
| `tests/` | Python tooling regression tests |
| `plugins/vibeguard/` | Optional Codex help skill, no second runtime or installer |
| `eval/` | Reproducible task fixture and evaluation protocol |
| `docs/` | Current user and runtime documentation |
| `plan/` | Accepted design and audit, not an automatic backlog |
| `.github/workflows/` | CI and tagged-release automation |

Old guards, wrapper, schemas, workflows, generated skills, and observability products are retired. History remains in Git. Do not restore retired validators solely to satisfy old tests.

See [installed paths and ownership](runtime-contract.md) and [verification commands](../CONTRIBUTING.md).
