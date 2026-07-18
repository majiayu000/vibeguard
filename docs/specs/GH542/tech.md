# Tech Spec

## Linked Issue

GH-542

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Hook resolution | `hooks/run-hook.sh:42-53` | Runs from `~/.vibeguard/installed/hooks/`, falls back to repo-path | Where the snapshot is consumed |
| Snapshot version | `scripts/setup/install.sh:366,468` | Captures git short-HEAD at install | The pinned marker to compare |
| Rules | `scripts/setup/targets/claude-home.sh:285` | Symlinked live to repo | The live side that drifts ahead |
| Repo pointer | `~/.vibeguard/repo-path` | Absolute path to the repo | Source for live HEAD lookup |
| Check entry | `setup.sh --check` (if present) | Health checks | Natural home for a drift check |

## Proposed Design

Add a lightweight drift check with two surfaces:

1. `setup.sh --check`: compare `~/.vibeguard/installed/version` against `git -C "$(cat ~/.vibeguard/repo-path)" rev-parse --short HEAD`; report drift with the remedy.
2. Optional hot-path warn: in `run-hook.sh` (or a once-per-session guard), if the two differ, emit a non-blocking warning via the existing warn channel, throttled to once per session (reuse session-id state). No-op cleanly when repo-path is missing.

Keep it advisory: never change exit code or block. Prefer computing the live HEAD at most once per session to avoid `git rev-parse` on every event.

## Product-to-Test Mapping

| Product invariant | Implementation area | Verification |
| --- | --- | --- |
| P1 comparable versions | drift-check function | unit test on version compare |
| P2 warn on drift | run-hook.sh warn / --check | simulate drift, assert warning |
| P3 names remedy | warning text | assert message mentions setup.sh |
| P4 non-blocking | advisory path | assert exit code unchanged on drift |
| P5 silent when equal | drift-check function | equal HEADs → no warning |

## Data Flow

`installed/version` (file) + live `git rev-parse` (repo-path) → compare → optional warn via existing warn channel, throttled by session-id state. No new persistence beyond a once-per-session marker.

## Alternatives Considered

- Auto-reinstall on drift: rejected — surprising, and running install mid-session is risky.
- Live-repo hook execution: rejected — reintroduces the dirty-dev-tree breakage the snapshot avoids (`install.sh:442` comment).

## Risks

- Security: none material (read-only comparison).
- Compatibility: must no-op when repo-path/repo is absent.
- Performance: bound `git rev-parse` to once per session to avoid per-event cost.
- Maintenance: small, self-contained check.

## Test Plan

- [ ] Unit tests: version-compare function (equal, drifted, missing repo).
- [ ] Integration tests: bump repo HEAD without reinstall → warning; no drift → silent.
- [ ] Manual verification: `git pull` that changes a hook, observe the warning, run `setup.sh`, warning clears.

## Rollback Plan

Remove the drift-check call; behavior returns to no-warning. No data migration.
