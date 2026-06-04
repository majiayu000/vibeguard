# Spec: PostToolUse malformed input should fail visibly

- Status: Draft
- Date: 2026-06-04
- Owner: @majiayu000
- Issue: https://github.com/majiayu000/vibeguard/issues/373
- Readiness: plan_first
- Severity: P1
- Suggested labels: `bug`, `P1`, `guard`, `review`
- Related: `vibeguard-runtime/src/hook_checks.rs`, `vibeguard-runtime/src/hook_checks_write.rs`, `hooks/post-edit-guard.sh`, `hooks/post-write-guard.sh`, `hooks/pre-write-guard.sh`

## Problem

PostToolUse guards silently pass malformed JSON input. This violates the
repository's no-silent-degradation rule: a malformed hook payload means the guard
cannot know which file changed, so a user-visible post-write or post-edit finding
can be missed with no warning.

The pre-write path already treats malformed JSON as visible malformed input.
Post-edit and post-write should match that safety posture.

## Verified facts

- `vibeguard-runtime/src/hook_checks.rs` prints `SKIP` and returns success when
  `post_edit_fast_check` receives malformed JSON.
- `hooks/post-edit-guard.sh` exits 0 on `SKIP`.
- `vibeguard-runtime/src/hook_checks_write.rs` returns success with no output when
  `post_write_check` receives malformed JSON.
- `hooks/post-write-guard.sh` exits 0 whenever the runtime command succeeds.
- `vibeguard-runtime/src/hook_checks.rs` already emits `MALFORMED` for malformed
  pre-write JSON, and `hooks/pre-write-guard.sh` turns that into visible hook
  output.

Audit reproduction:

```bash
printf 'not-json' | cargo run --quiet --manifest-path vibeguard-runtime/Cargo.toml -- \
  post-edit-fast-check 400 audit-session codex /tmp/vibeguard-audit-post-edit.jsonl
# Actual: SKIP, exit 0

printf 'not-json' | cargo run --quiet --manifest-path vibeguard-runtime/Cargo.toml -- \
  post-write-check 800 400 5000 20 5 /tmp/vibeguard-audit-post-write.jsonl
# Actual: empty output, exit 0

printf 'not-json' | cargo run --quiet --manifest-path vibeguard-runtime/Cargo.toml -- \
  pre-write-check 800 400
# Existing safer contrast: MALFORMED
```

## Goals

- G1: Malformed PostToolUse JSON is visible to the user or hook log.
- G2: Valid non-file PostToolUse events remain no-op and do not create noisy
  false positives.
- G3: Post-edit and post-write malformed handling is consistent with pre-write.
- G4: Tests cover runtime subcommands and shell wrappers.

## Non-goals

- Do not make every post hook blocking. PostToolUse can remain advisory, but it
  must not be silent on malformed input.
- Do not change Claude/Codex hook payload schemas.
- Do not broaden checks beyond malformed or structurally unusable hook input.

## Design

### 1. Split malformed input from irrelevant input

Runtime checks should distinguish:

- malformed JSON: visible error or warning.
- valid JSON that is not a supported file event: silent no-op is allowed.
- valid file event missing required fields: visible warning, because the guard
  expected a file event but cannot inspect it.

### 2. Emit a stable runtime token for malformed post input

Use a stable token such as `MALFORMED` or `HOOK_ERROR` for
`post-edit-fast-check` and `post-write-check`. The shell wrappers then translate
that token into hook output.

The exact token can reuse the pre-write `MALFORMED` pattern if it keeps the
wrapper code smaller.

### 3. Make shell wrappers visible but proportionate

`hooks/post-edit-guard.sh` and `hooks/post-write-guard.sh` should:

- exit non-zero only if that is compatible with the host's PostToolUse contract;
  otherwise exit 0 with explicit additional context.
- write a `warn` or `error` event when malformed input prevents inspection.
- include the first bounded slice of parse error context, without dumping large
  payloads.

### 4. Add regression tests

Tests should cover:

- malformed JSON to runtime subcommands.
- malformed JSON through shell wrappers.
- valid non-file PostToolUse payload remains silent.
- valid post-edit/post-write file payloads still run the existing checks.

## Acceptance criteria

- AC1: `post-edit-fast-check` on `not-json` no longer returns plain `SKIP` with
  no visible warning.
- AC2: `post-write-check` on `not-json` no longer returns success with empty
  output.
- AC3: `post-edit-guard.sh` and `post-write-guard.sh` produce visible hook
  context or hook log entries for malformed payloads.
- AC4: Valid non-file PostToolUse events still exit 0 without user noise.
- AC5: Existing pre-write malformed behavior remains unchanged.

## Verification

Run these commands before closing the issue:

```bash
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash tests/test_codex_runtime.sh
bash scripts/ci/validate-hooks.sh
bash scripts/ci/validate-hooks-manifest.sh
```

## Routing handoff

```yaml
handoff:
  mode: fixflow
  artifacts:
    - plan/spec-posttool-malformed-input-fail-visible.md
  runtime_pinning_snapshot: None for short direct implementation; capture W-20 if this expands into delegated or multi-session work.
  verification_owner: implementation owner
  stop_conditions:
    - Host PostToolUse contract forbids any visible warning/error output.
    - Tests show valid non-file PostToolUse events become noisy.
  lane_map:
    runtime_checks: implementation owner
    shell_wrappers: implementation owner
    regression_tests: implementation owner
```
