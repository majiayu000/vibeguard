# Product Spec

## Linked Issue

GH-542

## User Problem

VibeGuard runs hook/guard logic from a frozen install snapshot (`~/.vibeguard/installed/`, pinned to the git short-HEAD at install time) while rule text is a live symlink to the repo. After `git pull`, rule text updates immediately but hook/guard behavior does not change until `setup.sh` is re-run — and nothing warns the user. The result is silent drift between what the rules say and what the hooks actually enforce, with the only version marker being a one-time captured HEAD.

## Goals

- Detect when the installed hook snapshot diverges from the live repo HEAD.
- Warn the user (non-blocking) when drift exists so they know to re-run setup.
- Keep the snapshot's stability benefit (a dirty dev tree should not break hooks).

## Non-Goals

- Auto-reinstalling hooks on every `git pull` (surprising and potentially unsafe).
- Removing the snapshot in favor of live-repo execution (reintroduces the dirty-tree hazard).
- Versioning rule text (rules are intentionally live).

## Behavior Invariants

1. On hook execution (or `setup.sh --check`), the installed snapshot version is comparable against the live repo HEAD.
2. When `installed/version` differs from `git -C <repo-path> rev-parse --short HEAD`, a visible warning is surfaced (not a block).
3. The warning names the drift and the remedy (re-run `setup.sh`).
4. The drift check does not block or fail the hook — it is advisory and adds negligible latency.
5. When there is no drift, no warning is emitted.

## Acceptance Criteria

- [ ] A drift check compares `installed/version` with the live repo short-HEAD.
- [ ] Simulated drift (bump repo HEAD without reinstalling) produces a visible warning.
- [ ] No drift produces no warning.
- [ ] The check adds no blocking behavior and no meaningful hot-path latency.

## Edge Cases

- `repo-path` missing or repo deleted (check must no-op cleanly, not error).
- Detached HEAD / shallow clone where short-HEAD resolution differs.
- Rapid consecutive pulls (warning should not spam every event — throttle or emit once per session).

## Rollout Notes

Purely additive and advisory. Document the new warning and that the remedy is `setup.sh`. Optionally throttle the warning to once per session to avoid noise on the hot path.
