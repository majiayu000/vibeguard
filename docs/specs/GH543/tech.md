# Tech Spec

## Linked Issue

GH-543

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Clean entry | `scripts/setup/clean.sh:1-40` | Cleans claude/codex homes, unloads schedulers, `state_clean` | Where teardown is orchestrated |
| State clean | `scripts/lib/install-state.sh:125-127` | `state_clean` only `rm -f install-state.json` | Does not remove installed files |
| Claude clean | `scripts/setup/targets/claude-home.sh:487-541` | Removes claude surfaces, not `~/.vibeguard/*` | Missing the `~/.vibeguard` teardown |
| Install | `scripts/setup/install.sh:418-600` | Creates `~/.vibeguard/*` and repo `.git/hooks/{pre-commit,pre-push}` symlinks | The asymmetric counterpart |
| Project init | `scripts/project-init.sh:181-196` | Installs the same git-hook symlinks in other repos | Untracked third-party targets |

## Proposed Design

1. Add a `clean_vibeguard_home` step to `clean.sh` that removes the executable wrappers/links under `~/.vibeguard/` (`repo-path`, `run-hook.sh`, `installed/`, `pre-commit`, `pre-push`), preserving `projects/` and config unless `--purge-data`.
2. Add git-hook removal: for the vibeguard repo (and tracked `project-init` targets), delete `.git/hooks/{pre-commit,pre-push}` only when `readlink`/content confirms they resolve to VibeGuard wrappers.
3. Extend `install-state.json` to record `project-init` repo targets so their hooks are removable; if a target is untracked, report it as a manual-removal item rather than silently leaving it.
4. Add `--purge-data` to additionally `rm -rf ~/.vibeguard/projects` and config.

## Product-to-Test Mapping

| Product invariant | Implementation area | Verification |
| --- | --- | --- |
| P1 remove VG git hooks only | git-hook removal w/ ownership check | test: VG symlink removed, foreign hook kept |
| P2 remove wrappers | `clean_vibeguard_home` | test: wrappers gone after clean |
| P3 preserve data default | default clean path | test: `projects/` remains |
| P4 purge-data flag | `--purge-data` branch | test: `projects/` removed with flag |
| P5 idempotent | clean path guards | run clean twice, no error |
| P6 track project-init | `install-state.json` extension | test: recorded target removed; untracked reported |

## Data Flow

`clean.sh` reads `install-state.json` (extended with project-init targets) → removes owned files/symlinks → optional `--purge-data` removes history. No new runtime persistence; only teardown.

## Alternatives Considered

- `rm -rf ~/.vibeguard` unconditionally: rejected — destroys learn/GC history without consent.
- Leave git hooks and only document manual removal: rejected — that is the current asymmetry; at least VibeGuard-owned hooks in tracked repos should auto-remove.

## Risks

- Security: none material; teardown only.
- Compatibility: must never remove non-VibeGuard git hooks (ownership check is critical).
- Performance: n/a.
- Maintenance: `install-state.json` becomes the source of truth for third-party targets — keep install and clean in sync.

## Test Plan

- [ ] Unit tests: ownership check distinguishes VibeGuard vs foreign hooks.
- [ ] Integration tests: full clean removes wrappers + owned git hooks, preserves `projects/`; `--purge-data` removes history; idempotent re-run.
- [ ] Manual verification: install, `project-init` a scratch repo, `--clean`, confirm both repos' VibeGuard hooks removed and data preserved.

## Rollback Plan

Revert the `clean_vibeguard_home` and git-hook removal additions; teardown returns to prior (asymmetric) behavior. `install-state.json` schema addition is backward-compatible (extra field ignored by old code).
