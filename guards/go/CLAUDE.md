# guards/go/ directory

Go language guard script to perform static mode detection on Go projects.

## Script list

| Script | Rule ID | Detection Content |
|------|---------|----------|
| `check_error_handling.sh` | GO-01 | Unchecked error return value (assigned to _) |
| `check_goroutine_leak.sh` | GO-02 | Goroutine leak risk (go func without exit mechanism) |
| `check_defer_in_loop.sh` | GO-08 | Defer in loop (resource leak) |

## common.sh usage

All scripts introduce shared functions through `source common.sh`:
- `list_go_files <dir>` — List .go files (prefer git ls-files, exclude vendor/)
- `parse_guard_args "$@"` — parses --strict and target_dir
- `create_tmpfile` — Create an automatically cleaned temporary file

## Output format

```
[GO-XX] file:line problem description. Repair: specific repair methods
```
