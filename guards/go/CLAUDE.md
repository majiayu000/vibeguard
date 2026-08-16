# guards/go/ directory

Go language guard compatibility scripts. Detection is implemented by
`vibeguard-runtime scan go <rule> <path>`; each `check_*.sh` file is a thin
exec shim for existing callers.

## Script list

| Script | Rule ID | Detection Content |
|------|---------|----------|
| `check_error_handling.sh` | GO-01 | Unchecked error return value (assigned to _) |
| `check_goroutine_leak.sh` | GO-02 | Goroutine leak risk (go func without exit mechanism) |
| `check_defer_in_loop.sh` | GO-08 | Defer in loop (resource leak) |

## Runtime shim

All scripts source `runtime-shim.sh` and call `run_runtime_guard`. Do not add
detection logic, diff parsing, or a fallback scanner to shell. `common.sh`
exists only as a deprecated compatibility entrypoint.

## Output format

```
[GO-XX] file:line: problem description. Repair: specific repair methods
```
