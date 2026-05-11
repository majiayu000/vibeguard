# VibeGuard User Config

`setup.sh` seeds `~/.vibeguard/config.json` from `templates/vibeguard-config.json.example` on first install and preserves the file on later installs.

Resolution order is:

1. Environment variable
2. `VIBEGUARD_CONFIG_FILE`, or `~/.vibeguard/config.json`
3. Built-in default

| JSON key | Environment override | Default | Runtime surface |
| --- | --- | --- | --- |
| `u16.limit` | `VG_U16_LIMIT` | `800` | Pre-write, pre-edit, post-write, and post-edit U-16 file-size checks |
| `write_mode` | `VIBEGUARD_WRITE_MODE` | `warn` | `pre-write-guard.sh` new-source handling (`warn` or `block`) |
| `circuit_breaker.threshold` | `VG_CB_THRESHOLD` | `3` | Consecutive warns/blocks before a hook circuit opens |
| `circuit_breaker.cooldown_seconds` | `VG_CB_COOLDOWN` | `300` | Seconds an open hook circuit waits before half-open probe |
| `paralysis.threshold` | `VG_PARALYSIS_THRESHOLD` | `7` | Consecutive read-only operations before analysis-paralysis warning |

Malformed JSON, missing keys, wrong value types, and unsupported `write_mode` values fall back to the next layer instead of breaking hooks.
