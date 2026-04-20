# Directory Map

VibeGuard keeps runtime and installable source directories at the repository root because those paths are part of the public install, documentation, and CI contract. Internal research and planning material lives under `docs/internal/` so it does not look like product surface area.

## Product Core

| Path | Role |
|------|------|
| `rules/claude-rules/` | Canonical native rule source. Generated/reference surfaces must follow this source. |
| `hooks/` | Runtime hook scripts and hook adapters. Installed as part of the VibeGuard runtime snapshot. |
| `guards/` | Static guard scripts for universal and language-specific checks. |
| `schemas/` | Install/runtime contracts and project schema definitions. |
| `scripts/setup/`, `setup.sh` | Public setup entrypoint and target-specific install adapters. |
| `scripts/lib/`, `scripts/codex/` | Shared install/runtime helpers and Codex adapters. |
| `vg-helper/` | Optional Rust helper used to speed up hook-side parsing. |

## Workflow Surface

| Path | Role |
|------|------|
| `.claude/commands/` | Claude slash command source installed into `~/.claude/commands/`. |
| `agents/` | Claude agent prompt source installed into `~/.claude/agents/`. |
| `skills/` | Core reusable skills installed into Claude and Codex skill locations. |
| `workflows/` | Codex workflow skills and shared workflow references. |
| `context-profiles/` | Claude context profiles installed into `~/.claude/context-profiles/`. |
| `templates/` | Project and language templates copied or referenced by setup and docs. |
| `claude-md/` | Text injected into user-level Claude memory during setup. |

## Verification And Release

| Path | Role |
|------|------|
| `tests/` | Shell and unit regression tests for hooks, guards, setup, and contracts. |
| `eval/` | Evaluation samples and runner for rule compliance checks. |
| `scripts/ci/` | CI contract and static validation scripts. |
| `scripts/verify/` | Local verification and freshness checks. |
| `.github/` | GitHub Actions workflows, issue templates, and PR template. |
| `data/` | Rule precision and triage data used by quality tooling. |

## Documentation And Internal Notes

| Path | Role |
|------|------|
| `README.md`, `docs/README_CN.md` | Public product entrypoints. |
| `docs/rule-reference.md` | Public generated summary of the rule/guard surface. |
| `docs/how/`, `docs/reference/`, `docs/known-issues/` | Public or maintainer-facing explanations that describe current behavior. |
| `docs/assets/` | Demo media and scripts used by public docs. |
| `site/` | Static landing site deployed by GitHub Pages. |
| `docs/internal/` | Research notes, historical specs, benchmark designs, and cross-session follow-ups. |
| `plan/` | Active workflow output directory. Do not move until plan workflow specs change. |

## Change Rules

- Do not move product core or workflow surface directories without updating `schemas/install-modules.json`, setup targets, docs, and contract tests in the same change.
- Prefer moving historical or research-only material under `docs/internal/` before changing public runtime paths.
- After path changes, run the manifest and documentation validators before claiming completion.
