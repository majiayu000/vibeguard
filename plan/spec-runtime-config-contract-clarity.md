# Spec: Clarify project policy config versus user runtime config

- Status: Draft
- Date: 2026-06-04
- Owner: @majiayu000
- Issue: https://github.com/majiayu000/vibeguard/issues/374
- Readiness: plan_first
- Severity: P2
- Suggested labels: `documentation`, `P2`, `dx`, `review`
- Related: `README.md`, `templates/vibeguard-config.README.md`, `schemas/vibeguard-project.schema.json`, `scripts/setup/install.sh`, `scripts/lib/project_config_validate.py`

## Problem

The documentation currently mixes two different configuration surfaces:

- project policy config: `.vibeguard.json`
- user runtime config: `~/.vibeguard/config.json`

As a result, README guidance implies that runtime tuning keys such as
`write_mode`, `u16.warn_limit`, and `u16.limit` can be placed in
`.vibeguard.json`. The project schema rejects those keys because
`.vibeguard.json` is a policy file, not the per-user runtime-threshold file.

This creates a documentation/schema contract drift: a user following one doc path
can produce a config rejected by another supported path.

## Verified facts

- `README.md` describes `write_mode=block` and `u16.warn_limit` /
  `u16.limit`.
- `templates/vibeguard-config.README.md` documents
  `~/.vibeguard/config.json` as the runtime config file.
- `schemas/vibeguard-project.schema.json` has `additionalProperties: false` and
  does not include `write_mode` or `u16`.
- `scripts/setup/install.sh` prints "Runtime configuration (env vars or
  .vibeguard.json)", which conflates runtime tuning with project policy.

Audit reproduction:

```bash
tmp_cfg=$(mktemp)
printf '{"write_mode":"block"}\n' > "$tmp_cfg"
python3 scripts/lib/project_config_validate.py "$tmp_cfg" schemas/vibeguard-project.schema.json
# Actual: VibeGuard project config invalid: .write_mode: unknown property
rm -f "$tmp_cfg"
```

## Goals

- G1: Every public doc clearly states which keys belong in `.vibeguard.json`
  versus `~/.vibeguard/config.json`.
- G2: Setup and validation error messages point users to the right file.
- G3: The project schema remains strict for project policy keys.
- G4: If runtime config needs schema validation, it gets its own schema instead
  of expanding the project schema with user-only keys.

## Non-goals

- Do not merge project policy and user runtime config into one file.
- Do not relax `additionalProperties: false` on
  `schemas/vibeguard-project.schema.json`.
- Do not rename existing config files.
- Do not add unrelated documentation rewrites.

## Design

### 1. Define the two config surfaces in docs

Update README and template docs to use these terms consistently:

- `.vibeguard.json`: repository/project policy.
  Examples: profile, enforcement mode, disabled hooks, disabled rules.
- `~/.vibeguard/config.json`: user runtime tuning.
  Examples: write mode, U-16 thresholds, circuit breaker, paralysis guard.

The README should place project policy examples near policy behavior and user
runtime examples near local tuning behavior.

### 2. Fix setup wording

Change setup/check output that currently says runtime config may live in
`.vibeguard.json`. It should point project policy checks to `.vibeguard.json` and
runtime tuning checks to `~/.vibeguard/config.json`.

### 3. Improve validation diagnostics

When `project_config_validate.py` rejects user-runtime keys in
`.vibeguard.json`, the message should include a bounded hint:

```text
write_mode belongs in ~/.vibeguard/config.json, not .vibeguard.json
```

This can be a small known-key map for common drift keys instead of a broad schema
change.

### 4. Optional runtime-config schema

If the project wants machine validation for `~/.vibeguard/config.json`, add a
separate runtime-config schema under `schemas/`. Do not reuse the project policy
schema for that file.

## Acceptance criteria

- AC1: README no longer implies `write_mode` or `u16.*` belongs in
  `.vibeguard.json`.
- AC2: Setup/check output distinguishes project policy config from user runtime
  config.
- AC3: `.vibeguard.json` containing `write_mode` remains invalid, but the error
  message points to `~/.vibeguard/config.json`.
- AC4: The project schema still rejects unknown project-policy keys.
- AC5: Documentation path and command validators pass.

## Verification

Run these commands before closing the issue:

```bash
python3 scripts/lib/project_config_validate.py /path/to/test-project-config.json schemas/vibeguard-project.schema.json
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
bash tests/test_setup.sh
```

Use a temporary config fixture for the first command in implementation; do not
commit machine-specific paths.

## Routing handoff

```yaml
handoff:
  mode: fixflow
  artifacts:
    - plan/spec-runtime-config-contract-clarity.md
  runtime_pinning_snapshot: None
  verification_owner: implementation owner
  stop_conditions:
    - Fix requires changing the meaning of existing .vibeguard.json keys.
    - Runtime config validation needs a new schema larger than this documentation fix.
  lane_map:
    docs: implementation owner
    setup_messages: implementation owner
    validation_hint: implementation owner
```
