# Task Plan

## Linked Issue

GH-543

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP543-T1` Owner: agent — Add a VibeGuard-ownership check that confirms a `.git/hooks/{pre-commit,pre-push}` symlink resolves to a VibeGuard wrapper before removal. Done when: the check returns true only for VibeGuard-owned hooks. Verify: unit test with a VibeGuard symlink vs a foreign hook.
- [ ] `SP543-T2` Owner: agent — Add `clean_vibeguard_home` to `scripts/setup/clean.sh` removing `~/.vibeguard/` wrappers/links (`repo-path`, `run-hook.sh`, `installed/`, `pre-commit`, `pre-push`), preserving `projects/` and config by default. Done when: default clean removes wrappers, keeps data. Verify: integration test asserts wrappers gone, `projects/` present.
- [ ] `SP543-T3` Owner: agent — Remove owned git-hook symlinks for the vibeguard repo and tracked project-init targets, using T1's ownership check. Done when: VibeGuard hooks removed, foreign hooks untouched. Verify: integration test with mixed hooks.
- [ ] `SP543-T4` Owner: agent — Extend `install-state.json` (and `project-init.sh`) to record third-party repo targets; report untracked targets as manual-removal items. Done when: project-init targets are recorded and removable. Verify: init a scratch repo, clean, assert its hook removed.
- [ ] `SP543-T5` Owner: agent — Add a `--purge-data` flag that also removes `~/.vibeguard/projects/` and config, and make clean idempotent. Done when: purge removes history; double-run does not error. Verify: run with/without flag and twice.
- [ ] `SP543-T6` Owner: human — Confirm the ownership check is safe (never removes foreign hooks) and the data-preservation default is correct. Done when: maintainer approves. Verify: PR review approval recorded.

## Parallelization

T1 is a shared primitive consumed by T2/T3. T4 (state tracking) is independent but edits `install-state.json` + `project-init.sh`. T2/T3 edit `clean.sh` + targets — single owner to keep disjoint ownership per W-14. T6 gates merge.

## Verification

- Install, `project-init` a scratch repo, run `--clean`; confirm both repos' VibeGuard hooks removed, foreign hooks kept, `projects/` preserved.
- Run `--clean --purge-data`; confirm history removed. Re-run `--clean`; confirm no error.

## Handoff Notes

The ownership check (T1) is the safety-critical piece: never remove a `.git/hooks` entry that is not a VibeGuard wrapper. Default clean must preserve learn/GC history; only `--purge-data` deletes it. Third-party repo hooks are only auto-removable if tracked in `install-state.json` — untracked ones must be reported, not silently left.
