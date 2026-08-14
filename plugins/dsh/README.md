# VibeGuard for DeepSeek Harness

`@vibeguard/dsh` is a native DSH guardrail plugin that reuses the canonical hook scripts from an installed VibeGuard runtime. It connects every VibeGuard hook that has a matching DSH lifecycle surface:

| DSH lifecycle | VibeGuard hooks |
|---|---|
| `agent/session-start` + gated first `agent/pre-step` | `count-active-constraints` |
| `tools/pre-execute` for Bash/Edit/Write | `pre-bash-guard`, `pre-edit-guard`, `pre-write-guard` |
| `tools/post-execute` for Edit/Write/Bash | `post-edit-guard`, `post-write-guard`, `post-build-check` |
| `tools/post-execute` for Read/Glob/Grep | `analysis-paralysis-guard` |
| `agent/turn-stopping` | `stop-guard`, `learn-evaluator` |

DSH's `str_replace_editor` operations are normalized to Read, Edit, or Write before routing. After a successful mutation, an independent completion guard asks the agent to run verification if no configured verification command succeeds. Stop hooks and this completion guard can continue a turn only once, preventing feedback loops.

Every adapter decision uses the same JSON envelope:

```json
{
  "version": "vibeguard.dsh/v1",
  "decision": "deny",
  "signals": [
    {
      "signal_type": "command_policy",
      "signal": "vibeguard_pre_bash_deny",
      "reason": "..."
    }
  ]
}
```

## Requirements

- Node.js `^22.19` or `>=24`
- DeepSeek Harness `0.1.0-rc.5` or newer compatible prerelease
- VibeGuard installed by `./setup.sh`; by default the plugin uses the scripts in `~/.vibeguard/installed/hooks`

## Build and install locally

```bash
cd plugins/dsh
corepack pnpm install
corepack pnpm test
corepack pnpm build
corepack pnpm pack --pack-destination dist

dsh plugin --profile demo add ./dist/vibeguard-dsh-0.1.0.tgz
dsh --profile demo --dump-config
```

The bundle adds one Cordis row named `vibeguard`. It works in any profile that includes the DSH base bundle.

## Configuration

Override the inserted row from the profile's `cordis.patch.yml`:

```yaml
- id: vibeguard
  config:
    hooksDir: ''
    failureMode: closed
    timeoutMs: 5000
    buildTimeoutMs: 35000
    stdoutMaxBytes: 65536
    enabledHooks:
      - count-active-constraints
      - pre-bash-guard
      - pre-edit-guard
      - pre-write-guard
      - post-edit-guard
      - post-write-guard
      - post-build-check
      - analysis-paralysis-guard
      - stop-guard
      - learn-evaluator
    guardUnverifiedCompletion: true
    mutatingTools: [write, edit, str_replace_editor]
    verificationCommandPatterns:
      - '(^|[;&|]\\s*)pnpm\\s+(test|lint|check|build)(\\s|$)'
```

`hooksDir: ''` selects the installed snapshot. `failureMode: closed` fails visibly when any enabled hook cannot run cleanly, times out, is aborted, truncates its response, or emits an invalid structured result. Set it to `open` only when availability is more important than guard enforcement.

## Deliberate v0.1 limits

This package does not add a web UI, registry service, npm publication workflow, or dependency supply-chain scanner. It tracks mutations made through DSH's file-editing tools; shell-based file mutation classification is not included yet.

[中文说明](README.zh.md)
