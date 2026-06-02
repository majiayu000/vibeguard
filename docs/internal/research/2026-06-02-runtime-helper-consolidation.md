# Runtime Helper Consolidation Feasibility

Status: roadmap note for issue #343. This is not an implementation plan for an
all-at-once port.

## Goal

Reduce install friction by removing Python helpers from the hook runtime path
after the prebuilt `vibeguard-runtime` path has landed. The desired endpoint is
a single Rust runtime plus shell wrappers. This note inventories
`hooks/_lib/*.py`; removing the general Python 3 install prerequisite also
requires a separate pass over inline `python3` snippets in shell hooks and setup
helpers.

## Current Inventory

`hooks/_lib` currently has three Python helpers:

| Helper | Current callers | Role | Existing Rust coverage | Port complexity | Recommendation |
|--------|-----------------|------|------------------------|-----------------|----------------|
| `event_log.py` | `scripts/hook-health.sh`, `scripts/stats.sh`, `scripts/quality-grader.sh`, `hooks/_lib/post_edit_history.sh` | Decode JSONL event logs, tolerate malformed UTF-8, filter by timestamp | Partial: `vibeguard-runtime hook-status`, `session-metrics`, and the `log_query.rs`-backed commands already parse event logs for narrower commands | Low | Go first. Add a generic runtime event-log reader/query subcommand or extend existing `log_query.rs` paths, then migrate read-only report scripts. |
| `policy.py` | `hooks/_lib/policy.sh`, reached by `run-hook.sh` and `run-hook-codex.sh` before wrapped hooks execute | Validate user/project config, resolve hook manifest entries, apply enforcement/profile/disabled hook policy | Partial: Rust runtime has event schema, hook status, JSON helpers, and hook checks, but no policy/config gate equivalent | Medium | Go second. Port only after a Rust project-config validator and manifest lookup API exist; keep fail-closed semantics and diagnostics parity. |
| `codex_apply_patch_adapter.py` | `hooks/_lib/codex_runner.sh` via `run-hook-codex.sh` | Normalize Codex `apply_patch` command payloads into Write/Edit-shaped hook payloads | Partial: `vibeguard-runtime codex-app-server-wrapper` has Codex protocol logic, but this native-hook apply_patch normalizer is separate | High | Go last. Port only with fixture parity tests for add/update/delete/move patches, multi-file patches, malformed payloads, and permission/PostToolUse behavior. |

Previously duplicated Python helpers for session metrics and package command
rewrite are already represented by runtime subcommands (`session-metrics` and
`pkg-rewrite`), so they are not part of this remaining install-friction scope.

Known Python-dependent paths outside `hooks/_lib/*.py` include inline command
normalization in `hooks/pre-bash-guard.sh`, optional redaction logic in
`hooks/_lib/log_redact.sh`, and setup/CI helper scripts. They should be
inventoried before claiming a no-Python install.

## Go / No-Go

Recommendation: go for a staged consolidation, no-go for a single large port.

The remaining helpers are feasible to move into `vibeguard-runtime`, but they
sit on different risk surfaces:

- `event_log.py` is read-only and can move first with low blast radius.
- `policy.py` controls whether hooks run, skip, warn, or fail; a bad port can
  silently disable protection or block healthy installs.
- `codex_apply_patch_adapter.py` changes the payloads inspected by pre/post
  file hooks; a bad port can create false negatives for Codex apply_patch edits.

## Proposed Follow-Up Issues

1. Port event-log reading helpers to `vibeguard-runtime`.
   - Add a runtime command that preserves malformed UTF-8 tolerance and timestamp
     filtering.
   - Migrate `hook-health`, `stats`, `quality-grader`, and `post_edit_history`
     callers.
   - Acceptance: existing event-log malformed-input tests still pass, and Python
     import of `event_log.py` is no longer used by hook/report paths.

2. Port runtime policy gate to `vibeguard-runtime`.
   - Add project config validation, hook manifest lookup, profile filtering, and
     disabled-hooks handling.
   - Preserve exit codes used by `policy.sh`: allow, skip, policy error, config
     parse error.
   - Acceptance: policy tests cover enforcement `off`, `warn`, `block`, invalid
     config, missing helper/runtime, and Codex-visible error output.

3. Port Codex apply_patch normalization to `vibeguard-runtime`.
   - Add an apply_patch parser and normalized payload emitter.
   - Cover add/update/delete/move, multi-file patches, empty patches, malformed
     JSON, non-apply_patch payload passthrough, and post-build file payloads.
   - Acceptance: Codex native hook tests pass without
     `codex_apply_patch_adapter.py`.

## Validation Needed Before Removing Python

- `bash tests/test_setup.sh`
- `bash tests/test_setup_check.sh`
- `bash tests/test_codex_runtime.sh`
- `bash tests/test_hook_status.sh`
- `bash tests/test_hook_health.sh`
- `bash tests/test_quality_grader.sh`
- `bash tests/test_stats.sh`
- `bash tests/hooks/test_runtime_policy.sh`
- `bash tests/test_hooks.sh`
- `bash scripts/ci/validate-doc-paths.sh`
- `cargo test --locked --manifest-path vibeguard-runtime/Cargo.toml`

Only after all three follow-up ports and the separate inline-Python inventory
land should docs change from "requires Python 3" to a true single-runtime
install claim.
