# AGENTS.md instructions for VibeGuard

VibeGuard is an anti-hallucination rules, hooks, and workflow repository. There is no ORM, no front-end framework, and no microservices layer in this project.

## Project Rules

- Search first before adding files, functions, rules, hooks, workflows, or tests.
- Keep names snake_case unless an external API boundary requires camelCase.
- Do not swallow errors silently. User-visible missing data or wrong output must fail loudly.
- Do only the requested scope; avoid opportunistic refactors.
- Follow `workflows/references/routing-contract.md`: classify `work_surface` as `code_execution`, `writing_research`, or `chat_support` before setting `readiness` to `execute_direct`, `plan_first`, or `clarify_first`; handoffs carry `mode`, `artifacts`, `runtime_pinning_snapshot`, `verification_owner`, `stop_conditions`, and `lane_map`.
- High-context files such as `AGENTS.md`, `CLAUDE.md`, `.claude/settings*.json`, setup scripts, and hooks must not be modified by generated output without explicit intent.

## Validation

Before completion, run the focused test or check that covers the changed surface.

Before submission:

- Rust: `cargo check` and `cargo test`
- Shell/setup changes: `bash tests/test_setup.sh`
- Manifest/routing changes: `bash tests/test_manifest_contract.sh`
- Documentation path changes: `bash scripts/ci/validate-doc-paths.sh` and `bash scripts/ci/validate-doc-command-paths.sh`

If a validation command cannot run, report the exact blocker instead of claiming completion.
