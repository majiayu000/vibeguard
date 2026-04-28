# Signal Report: Codex Config Validation False Negative

Date: 2026-04-28
Rule context: U-23

## Signal

`setup.sh --check` reported the Codex config as healthy when `~/.codex/config.toml`
contained the literal line `codex_hooks = true`, even if the file was malformed TOML.

## Root Cause

`scripts/setup/targets/codex-home.sh` used a regex-only grep check for
`codex_hooks = true`. That logic was not structurally validating TOML and could
therefore produce a false-negative health signal for malformed or partially
corrupted config files.

## Deterministic Fix

Move the health check onto a parser-backed helper in
`scripts/lib/codex_config_toml.py` using Python `tomllib`, and have the setup
status path distinguish three states:

- `OK`: valid TOML with `[features].codex_hooks = true`
- `MISSING`: valid TOML but feature not enabled
- `INVALID`: malformed TOML

## Verification

Regression coverage added in:

- `tests/test_manifest_contract.sh`
- `tests/test_setup.sh`
