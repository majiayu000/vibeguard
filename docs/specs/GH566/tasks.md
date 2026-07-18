# Task Plan

## Linked Issue

GH-566

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP566-T1` Owner: agent — Add Codex hook command classification to `scripts/lib/codex_hooks_json.py` for managed, valid unmanaged, missing-target unmanaged, and unresolved unmanaged commands. Done when: direct absolute paths, interpreter script paths, and simple `env` prefixes are classified without deleting anything. Verify: helper unit coverage plus `python3 -m py_compile scripts/lib/codex_hooks_json.py`.
- [ ] `SP566-T2` Owner: agent — Promote missing-target unmanaged `PreToolUse` and `PermissionRequest` hooks to strict-check broken state in `scripts/setup/targets/codex-home.sh` / `scripts/setup/check.sh`. Done when: `setup --check --strict` names `config`, `event`, `matcher`, and `command_path`, and exits non-zero for the stale `PreToolUse` fixture. Verify: focused cases in `tests/test_setup_check.sh`.
- [ ] `SP566-T3` Owner: agent — Add an explicit repair command and setup flag for pruning missing-target unmanaged blocking hooks while preserving valid third-party hooks and VibeGuard-managed hooks. Done when: stale `PreToolUse` hook is removed, sibling valid hooks remain, JSON stays valid, and normal `setup.sh --yes` does not silently delete unmanaged hooks. Verify: focused setup flow test.
- [ ] `SP566-T4` Owner: agent — Replace preserved third-party hook fixtures in setup tests with real temporary scripts under `${TMP_HOME}` and add a HOME guard before writing hook fixtures. Done when: preservation tests no longer use '/existing/non-vibeguard.js' as a valid hook and fail fast if HOME is not a test temp directory. Verify: `bash tests/setup/install_flow_tests.sh` focused section or equivalent setup test command.
- [ ] `SP566-T5` Owner: agent — Add troubleshooting documentation for Codex `PreToolUse hook (failed)` caused by stale unmanaged hooks. Done when: docs explain inspection, direct reproduction, strict check, and explicit repair. Verify: `bash scripts/ci/validate-doc-paths.sh` and `bash scripts/ci/validate-doc-command-paths.sh`.
- [ ] `SP566-T6` Owner: human — Review repair semantics before implementation PR merge because it mutates `~/.codex/hooks.json`. Done when: maintainer confirms opt-in deletion boundaries are acceptable. Verify: PR review approval recorded.

## Parallelization

- T1 must land before T2 and T3.
- T2 and T3 can proceed after T1 but should share one owner for `scripts/lib/codex_hooks_json.py`.
- T4 can run in parallel with T1 if it only changes tests and fixture setup.
- T5 can run after T2/T3 wording stabilizes.
- T6 gates merge readiness for the implementation PR.

## Verification

- `python3 -m py_compile scripts/lib/codex_hooks_json.py`
- `bash tests/test_setup_check.sh`
- Focused setup flow test covering valid third-party preservation plus stale unmanaged pruning
- `bash scripts/ci/validate-doc-paths.sh`
- `bash scripts/ci/validate-doc-command-paths.sh`

## Handoff Notes

- This spec intentionally preserves the “do not delete third-party hooks by default” safety rule.
- Do not repair by wiping `~/.codex/hooks.json` or replacing the whole file.
- Do not weaken existing assertions that VibeGuard-managed hooks are preserved/removed correctly.
- Keep all user-facing output explicit: stale hook command, event, matcher, and exact repair command.
