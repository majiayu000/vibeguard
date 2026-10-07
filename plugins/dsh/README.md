# VibeGuard for DeepSeek Harness

[中文](README.zh.md)

`@vibeguard/dsh` forwards DSH Bash pre/post events to the local VibeGuard Rust executable. Command policy and outcome storage remain in Rust.

| DSH boundary | Behavior |
|---|---|
| `tools/pre-execute`, tool `bash` | Call `vibeguard-runtime hook dsh` with PreToolUse JSON on stdin. A policy denial becomes native `ask`; a runtime failure becomes hard `deny`. |
| `tools/post-execute`, tool `bash` | Forward structured exit/error/background facts as PostToolUse. Observation warnings preserve the completed result. |

DSH ToolRuntime requests approval through its own ApprovalService. Allowed-once dispatches once; rejection, cancellation, unavailable approval, missing service, and agent-less calls deny dispatch. Other downstream policy denials remain denials. Runtime errors cannot be approved away.

This adapter does not register session-start, Stop, Read, Edit or Write hooks: current VibeGuard v2 has no policy for those events. It does not infer verification from command names, inspect task completion, or execute proposed commands itself. Its limited Bash recognizer is documented in the [runtime contract](../../docs/runtime-contract.md).

## Requirements and local installation

- Node.js `^22.19.0` or `>=24`
- DSH packages **0.2.0-rc.2** (`next`), tested as published npm artifacts. No claim of compatibility with other prereleases.
- VibeGuard **2.0.2** or a binary built from this revision, supporting `hook dsh`; old binaries fail closed.

From the VibeGuard checkout:

```bash
cargo build --locked --manifest-path vibeguard-runtime/Cargo.toml
cd plugins/dsh
npm ci
npm run check
npm test
npm pack --pack-destination dist

dsh plugin --profile demo add ./dist/vibeguard-dsh-0.1.0.tgz
dsh --profile demo --dump-config
```

The `vibeguard` bundle row requires the profile's normal DSH base bundle and a mounted shell executor. Override its config in the profile's `cordis.patch.yml`:

```yaml
- id: vibeguard
  config:
    runtimePath: /absolute/path/to/vibeguard-runtime
    stateDir: /absolute/path/to/vibeguard-state
    timeoutMs: 5000
```

Empty paths select `~/.vibeguard/bin/vibeguard-runtime` and `~/.vibeguard/state`. Missing binary aborts plugin loading with a build instruction; it is never downloaded automatically. `timeoutMs` bounds each runtime call. Install the current release binary or point `runtimePath` to `vibeguard-runtime/target/debug/vibeguard-runtime`.

The runtime uses the profile's shell executor and sandbox. Give `stateDir` a writable location inside the configured workspace when the sandbox restricts home-directory writes; an unavailable observation directory produces a notice. The adapter does not add sandbox exemptions.

Only `dsh.json`, the latest observation, is stored. It contains host, event, timestamp, cwd, tool-use ID, outcome and optional exit code, never raw commands/output. Printed success text does not become an inferred exit code. An approved policy block initially records the policy denial; a dispatched result then replaces it with its actual outcome.

## Validation

`npm test` composes real Cordis, ToolRuntime, ApprovalService, Session, AgentLoop and local subprocess/shell services. A test Bash tool records dispatch without evaluating its input; dangerous payloads go only to the real Rust guard on stdin. Tests cover native approval outcomes and audit events, missing approval, cancellation, runtime/protocol failure, structured result observations and teardown.

The package is a local publish-ready artifact; installation examples use a tarball until its npm version is published.

Official seams: [tools](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/core/tools), [user approval](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/interaction/user-approval), [shell](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/shell/shell). These sources iterate; the published version above defines the tested API.
