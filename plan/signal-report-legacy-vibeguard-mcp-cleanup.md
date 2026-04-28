# Signal Report: Legacy Vibeguard MCP Cleanup

## Summary
- Rule: `U-23`
- Area: `scripts/lib/codex_config_toml.py`
- Reproduced on: `2026-04-28`

## Reproduction
Input:

```toml
[features]
foo = true

[mcp_servers.vibeguard]
command = "node"

[mcp_servers.vibeguard.env]
FOO = "bar"

[other]
value = 1
```

Observed output from `_remove_legacy_vibeguard_mcp()`:

```toml
[features]
foo = true

[mcp_servers.vibeguard.env]
FOO = "bar"

[other]
value = 1
```

## Root Cause
- The cleanup loop enters legacy-removal mode only for the exact table name `mcp_servers.vibeguard`.
- At the next table header, it immediately clears `in_legacy`, even when that next table is a child table such as `mcp_servers.vibeguard.env`.
- Result: nested legacy subtables survive cleanup and TOML parsing recreates the `mcp_servers.vibeguard` namespace.

## Affected Files
- `scripts/lib/codex_config_toml.py`: legacy MCP cleanup helper.
- `tests/test_manifest_contract.sh`: closest existing regression coverage for the helper CLI.

## Constraints
- Must remove the exact legacy table and any nested table whose name starts with `mcp_servers.vibeguard.`.
- Must not remove unrelated tables such as `[other]`.
- Must keep the fix deterministic and local to the cleanup helper.

## Verification Plan
- Extend `tests/test_manifest_contract.sh` with a nested-subtable regression.
- Run the targeted regression script after the patch.
