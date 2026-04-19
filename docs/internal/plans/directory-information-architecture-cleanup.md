# Directory Information Architecture Cleanup Plan

## Goal

Reduce top-level repository noise without changing VibeGuard runtime, install, or public command contracts.

## Scope

- Add a documented directory map for contributors.
- Move internal research, historical design, benchmark design, and follow-up notes under `docs/internal/`.
- Keep runtime and installable source directories at the repository root.

## Non-goals

- Do not move `hooks/`, `guards/`, `rules/`, `scripts/`, `schemas/`, `.claude/commands/`, `agents/`, `skills/`, or `workflows/`.
- Do not change install targets under `~/.claude/`, `~/.codex/`, or `~/.vibeguard/`.
- Do not move `plan/` in this pass, because current workflow skills write plan artifacts there.

## Verification

- `bash scripts/ci/validate-manifest-contract.sh`
- `bash scripts/ci/validate-doc-paths.sh`
- `bash scripts/ci/validate-doc-command-paths.sh`
- `bash scripts/verify/doc-freshness-check.sh --strict`
- `bash tests/test_manifest_contract.sh`
