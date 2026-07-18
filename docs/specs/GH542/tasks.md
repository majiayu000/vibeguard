# Task Plan

## Linked Issue

GH-542

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP542-T1` Owner: agent — Add a drift-check function comparing `~/.vibeguard/installed/version` with `git -C "$(cat ~/.vibeguard/repo-path)" rev-parse --short HEAD`, no-op when repo-path/repo is absent. Done when: function returns drift/no-drift/unknown correctly. Verify: unit test covering equal, drifted, missing-repo.
- [ ] `SP542-T2` Owner: agent — Wire the drift check into `setup.sh --check` with an actionable message naming `setup.sh` as the remedy. Done when: `--check` reports drift when present. Verify: simulate drift, run `--check`, assert message.
- [ ] `SP542-T3` Owner: agent — Add an optional once-per-session advisory warn in `run-hook.sh` (throttled via session-id state), never blocking. Done when: drift warns at most once per session, exit code unchanged. Verify: fire two events under drift, assert single non-blocking warning.
- [ ] `SP542-T4` Owner: agent — Ensure the live HEAD is computed at most once per session to avoid per-event `git rev-parse` cost. Done when: no per-event git call in the steady state. Verify: trace/inspect that rev-parse is cached per session.
- [ ] `SP542-T5` Owner: human — Confirm the warning cadence is acceptable (not noisy) and the remedy text is clear. Done when: maintainer approves. Verify: PR review approval recorded.

## Parallelization

T1 is the shared primitive; T2 and T3 both consume it and can proceed once T1 lands (they edit different files — `setup.sh` vs `run-hook.sh`, disjoint per W-14). T4 refines T3. T5 gates merge.

## Verification

- Simulate drift (bump repo HEAD without reinstall), run `setup.sh --check`, confirm warning; reinstall, confirm cleared.
- Fire two hook events under drift, confirm a single non-blocking warning and unchanged exit codes.

## Handoff Notes

Keep this advisory — never block on drift. The snapshot exists on purpose (a dirty dev tree must not break hooks), so the fix is visibility, not live-repo execution. Throttle the hot-path warning to once per session to avoid noise; the `--check` surface can report unconditionally.
