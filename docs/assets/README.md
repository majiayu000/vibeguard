# VibeGuard Demo Assets

Scripts and rendered media for the README demo.

## Files

| File | Purpose |
|------|---------|
| `record-demo.sh` | One-command recorder: runs the scenario through asciinema and renders a GIF via agg |
| `demo-scenario.sh` | Scripted scenario that invokes real VibeGuard guards against a throw-away project |
| `demo.cast` | Latest asciinema recording (asciicast-v2, generated) |
| `demo.gif` | Rendered GIF that can be embedded in the README (generated) |

## Recording a fresh demo

```bash
# macOS
brew install asciinema agg

bash docs/assets/record-demo.sh
```

This will:

1. Record `demo-scenario.sh` into `demo.cast`
2. Render `demo.cast` into `demo.gif` via `agg`

## Replay without re-recording

```bash
bash docs/assets/record-demo.sh --play     # replay cast in terminal
bash docs/assets/record-demo.sh --render   # re-render GIF only
```

## Embedding in the README

Once `demo.gif` exists, reference it from the top-level README:

```markdown
![VibeGuard demo](docs/assets/demo.gif)
```

## Notes

- `demo-scenario.sh` plants a deliberately buggy project in a `mktemp` directory and cleans it up on exit.
- The scenario calls the real guard scripts so the output reflects current behavior.
- Path resolution order for VibeGuard root: `$VG` env var → `~/vibeguard` → this repo (auto-detected).
- If guard output changes, rerun `record-demo.sh` to keep the demo honest.
