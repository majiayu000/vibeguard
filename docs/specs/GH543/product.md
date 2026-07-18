# Product Spec

## Linked Issue

GH-543

## User Problem

`setup.sh --clean` is not symmetric with install. It removes the `~/.claude`/`~/.codex` surfaces but leaves `~/.vibeguard/` (repo-path, run-hook.sh, installed/, config.json, pre-commit/pre-push wrappers, circuit-breaker/, projects/) and the `.git/hooks/{pre-commit,pre-push}` symlinks it installed into the vibeguard repo and any `project-init`-ed repo. After "uninstalling", those repos still trigger VibeGuard git hooks. It fails soft if the repo is later deleted, but the state and hooks persist indefinitely.

## Goals

- Make `--clean` remove the git-hook symlinks VibeGuard installed when they resolve to VibeGuard wrappers.
- Make `--clean` remove the executable wrappers and links under `~/.vibeguard/` that install created.
- Preserve user data (logs, learn/GC history) unless the user explicitly opts into a full purge.

## Non-Goals

- Deleting user learn/GC history by default.
- Removing symlinks from repos VibeGuard never touched.
- Changing what install creates (this is about symmetric teardown).

## Behavior Invariants

1. `--clean` removes `.git/hooks/{pre-commit,pre-push}` only when they resolve to VibeGuard wrappers (never third-party hooks).
2. `--clean` removes the executable wrappers/links under `~/.vibeguard/` (`repo-path`, `run-hook.sh`, `installed/`, `pre-commit`, `pre-push`).
3. By default, `--clean` preserves `~/.vibeguard/projects/` (learn/GC history) and config.
4. A `--purge-data` flag additionally removes `~/.vibeguard/projects/` and config.
5. `--clean` is idempotent and no-ops cleanly when a target is already absent.
6. Third-party repos VibeGuard modified are tracked so their hook symlinks can be removed (or the limitation is reported explicitly).

## Acceptance Criteria

- [ ] After `--clean`, the vibeguard repo's `.git/hooks/{pre-commit,pre-push}` VibeGuard symlinks are gone; non-VibeGuard hooks are untouched.
- [ ] After `--clean`, the `~/.vibeguard/` executable wrappers/links are removed; `projects/` remains unless `--purge-data`.
- [ ] `--purge-data` removes `projects/` and config.
- [ ] Running `--clean` twice does not error.

## Edge Cases

- `.git/hooks/pre-commit` exists but points to a non-VibeGuard hook (must be left alone).
- User has a custom hook chaining VibeGuard (detect VibeGuard ownership before removal).
- `project-init`-ed third-party repos not recorded in `install-state.json` (report as a known limitation if untracked).
- Repo already deleted (no-op cleanly).

## Rollout Notes

Document that `--clean` now fully removes executable surfaces and that `--purge-data` is required to also drop history. Because third-party repo symlinks are only removable if tracked, extend `install-state.json` to record `project-init` targets, or clearly document that those must be removed manually.
