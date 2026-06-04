# Spec: App-server runtime policy gate and required-hook fail closed

- Status: Draft
- Date: 2026-06-04
- Owner: @majiayu000
- Issue: https://github.com/majiayu000/vibeguard/issues/372
- Readiness: plan_first
- Severity: P1
- Suggested labels: `bug`, `P1`, `guard`, `review`
- Related: `vibeguard-runtime/src/codex_app_server_core.rs`, `vibeguard-runtime/src/codex_app_server_strategies.rs`, `vibeguard-runtime/src/codex_app_server_file_changes.rs`, `hooks/run-hook.sh`, `hooks/run-hook-codex.sh`, `hooks/_lib/policy.py`

## Problem

The Codex app-server wrapper invokes hook scripts directly through `HookRunner`.
That path bypasses the runtime policy gate normally enforced by
`hooks/run-hook.sh` and `hooks/run-hook-codex.sh`. A project can declare
`disabled_hooks` in `.vibeguard.json`, but the app-server wrapper still executes
the disabled hook and may block the user.

The same path also fails open when a hook script is missing. `HookRunner::run`
returns `HookResult::pass()` if the hook file does not exist, so a missing
required pre-hook can make a dangerous request invisible instead of producing a
hook error.

## Verified facts

- `vibeguard-runtime/src/codex_app_server_core.rs` returns pass when
  `hook_path.exists()` is false.
- `vibeguard-runtime/src/codex_app_server_strategies.rs` calls
  `pre-bash-guard.sh` through `HookRunner`, not through the policy wrapper.
- `vibeguard-runtime/src/codex_app_server_file_changes.rs` does the same for
  pre-edit, pre-write, post-edit, and post-write hooks.
- `hooks/run-hook.sh` and `hooks/run-hook-codex.sh` apply policy before
  dispatching hooks; the app-server Rust path does not.

Reproduction from the audit:

```bash
tmp_repo=$(mktemp -d)
mkdir -p "$tmp_repo/hooks"
printf '{"disabled_hooks":["pre-bash-guard"]}\n' > "$tmp_repo/.vibeguard.json"
cat > "$tmp_repo/hooks/pre-bash-guard.sh" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$tmp_repo/hooks/pre-bash-guard.sh"

# Run an app-server command-approval request in tmp_repo.
# Expected: disabled hook is skipped.
# Actual: app-server wrapper still runs the hook and declines the request.
```

Missing-hook reproduction from the audit:

```bash
tmp_repo=$(mktemp -d)
# Do not create hooks/pre-bash-guard.sh.

# Run an app-server command-approval request for `rm -rf /`.
# Expected: visible hook_error or decline because required pre-hook is missing.
# Actual: HookRunner returns pass and the request is forwarded with no response.
```

## Goals

- G1: App-server hook dispatch honors project policy from `.vibeguard.json` for
  `disabled_hooks`, profile, and enforcement mode.
- G2: Missing required pre-hooks fail visibly instead of passing silently.
- G3: Behavior stays consistent with the existing shell wrappers.
- G4: The Rust app-server path remains usable without introducing a new runtime
  dependency on Python for every request.

## Non-goals

- Do not redesign the full policy schema.
- Do not change the public Codex app-server protocol.
- Do not weaken existing shell-wrapper policy tests.
- Do not add opportunistic hook refactors outside the app-server dispatch path.

## Design

### 1. Add a Rust-side app-server policy gate

Introduce a small Rust policy evaluator used by `HookRunner` before it executes a
hook. It should load `.vibeguard.json` from the active project directory and mirror
the existing wrapper-level decisions for the fields the app-server path needs:

- `disabled_hooks`
- profile / enforcement mode
- invalid project policy handling

The preferred shape is a `runtime_policy` module that returns a structured
decision:

```text
run
skip(reason)
warn(reason)
hook_error(reason)
```

This keeps app-server dispatch Rust-native while preventing policy drift from
being hidden in individual strategy modules.

### 2. Classify required versus optional hooks

`HookRunner` needs to know whether the target hook is required for the current
request:

- Required pre-hooks: `pre-bash-guard.sh`, `pre-write-guard.sh`,
  `pre-edit-guard.sh`.
- Optional/post-observation hooks: `post-edit-guard.sh`,
  `post-write-guard.sh`, and other future post hooks.

If policy says a required hook is disabled, skip it intentionally and emit an
audit-visible skip reason. If policy allows a required hook but the file is
missing, return `hook_error` or a decline response instead of `pass`.

### 3. Preserve wrapper semantics for warn mode

When project policy resolves to warn mode, app-server should not hard decline
solely because a guard reported a warning-class finding. It should attach visible
context to the app-server response in the same spirit as the shell wrappers.

### 4. Add regression coverage

Add focused tests for:

- disabled `pre-bash-guard` skips in app-server command approval.
- missing `pre-bash-guard` fails visibly in app-server command approval.
- disabled file hook skips in app-server file-change flows.
- invalid `.vibeguard.json` produces a visible policy error instead of silent
  pass.
- shell wrapper behavior remains unchanged.

## Acceptance criteria

- AC1: With `.vibeguard.json` containing
  `{"disabled_hooks":["pre-bash-guard"]}`, an app-server command approval request
  for a command normally blocked by `pre-bash-guard.sh` is not declined by that
  hook.
- AC2: With no `hooks/pre-bash-guard.sh` present, the same request returns a
  visible hook failure rather than silently forwarding the request.
- AC3: With a valid blocking hook and no disabling policy, app-server still
  blocks the dangerous command.
- AC4: App-server file-change requests honor disabled pre/post file hooks.
- AC5: Invalid `.vibeguard.json` is visible in the response or hook log; it does
  not degrade to an unlogged pass.
- AC6: Existing shell-wrapper runtime policy tests still pass.

## Verification

Run these commands before closing the issue:

```bash
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash tests/hooks/test_runtime_policy.sh
bash tests/test_codex_runtime.sh
bash scripts/ci/validate-manifest-contract.sh
```

## Routing handoff

```yaml
handoff:
  mode: fixflow
  artifacts:
    - plan/spec-app-server-runtime-policy-gate.md
  runtime_pinning_snapshot: None for short direct implementation; capture W-20 if this expands into delegated or multi-session work.
  verification_owner: implementation owner
  stop_conditions:
    - Missing-hook behavior cannot be made visible without changing the public Codex app-server protocol.
    - Rust policy behavior would intentionally diverge from hooks/_lib/policy.py.
  lane_map:
    runtime_policy: implementation owner
    app_server_tests: implementation owner
    shell_wrapper_regression: implementation owner
```
