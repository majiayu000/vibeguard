# Spec: Remove Legacy MCP And Publish Residue

## Goal

Remove the old `mcp-server` / npm publish / Docker release surface from VibeGuard so the repository, setup flow, CI, and primary docs all match the current scripts-and-hooks architecture.

## Facts

- The repository no longer contains `mcp-server/`, `package.json`, or `Dockerfile`.
- Setup and CI still reference the removed MCP server and npm publish pipeline.
- Claude and Codex setup still contain legacy MCP cleanup gaps.
- Primary docs still describe MCP tools, Docker image usage, and Codex MCP configuration.

## Scope

1. Stop installing any VibeGuard MCP configuration for Claude or Codex.
2. Remove repository-owned legacy MCP/publish artifacts:
   - MCP-only CI validators
   - npm publish workflow and tarball verification script
   - Docker workflow and repo-local Docker publish files
3. Remove dead hook integration tied to the removed MCP tools:
   - `post-guard-check.sh`
   - Claude `mcp__vibeguard__guard_check` matcher
4. Update primary docs and setup tests to match the new architecture.
5. Preserve cleanup of previously installed legacy MCP entries in user config files.

## Non-Goals

- Do not change guard script behavior beyond removing dead MCP-only glue.
- Do not rewrite historical changelog or archival analysis documents that already clearly mark removed components as historical.
- Do not add a replacement publish pipeline.

## Affected Files

- Setup/runtime: `scripts/lib/settings_json.py`, `scripts/setup/lib.sh`, `scripts/setup/check.sh`, `scripts/setup/install.sh`, `scripts/setup/targets/claude-home.sh`, `scripts/setup/targets/codex-home.sh`
- CI/release: `.github/workflows/ci.yml`, `.github/workflows/publish.yml`, `.github/workflows/docker.yml`, `scripts/ci/validate-config-contract.sh`, `scripts/ci/validate-wiring-contract.sh`, `scripts/verify/verify-package-contents.sh`, `.npmignore`, `.dockerignore`
- Hooks/docs/schema/tests: `hooks/post-guard-check.sh`, `hooks/CLAUDE.md`, `schemas/install-modules.json`, `README.md`, `docs/README_CN.md`, `tests/test_setup.sh`, `.claude/commands/vibeguard/review.md`, `.claude/commands/vibeguard/cross-review.md`, `skills/eval-harness/SKILL.md`

## Verification

- `bash tests/test_setup.sh`
- `bash tests/test_hooks.sh`
- `bash tests/test_rust_guards.sh`
- `bash tests/unit/run_all.sh --fast`
