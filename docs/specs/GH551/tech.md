# Tech Spec

## Linked Issue

GH-551

## Product Spec

`docs/specs/GH551/product.md`

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Shared hook bootstrap | `hooks/log.sh` | Sourced by every hook; recomputes project hash via `git rev-parse` + `shasum` (~70ms), resolves the runtime binary (debug before release), then sources six `_lib` files | Largest fixed cost paid on every invocation; binary resolution order distorts benchmarks |
| Session inference | `hooks/_lib/log_session.sh` | Walks ancestor processes with repeated `ps` forks to infer CLI + session id, plus `find`/`mktemp` session-file management | Several forks per invocation; logic already deterministic and portable to Rust |
| Event logging | `hooks/_lib/log_write.sh` | Each `vg_log` forks `perl` (timestamp) and `date`, runs 8 command substitutions to build JSON, then calls `vibeguard-runtime append-jsonl` twice (project + global) | Hooks call `vg_log` 1-3 times per run; this multiplies fork cost |
| Circuit breaker | `hooks/circuit-breaker.sh` | 600-line bash state machine with ~48 command substitutions | Sourced and exercised by pre-write/pre-edit hot paths |
| Hook entry scripts | `hooks/pre-write-guard.sh`, `hooks/pre-bash-guard.sh`, `hooks/pre-edit-guard.sh`, `hooks/stop-guard.sh`, `hooks/post-edit-guard.sh`, `hooks/post-write-guard.sh`, `hooks/learn-evaluator.sh` | Orchestrate: parse stdin via runtime, branch on status, log, emit decision JSON | Become thin wrappers after migration |
| Wrapper | `hooks/run-hook.sh` | Resolves installed hook path, applies policy profile, drains stdin | Unchanged entry point; policy downgrade must keep working |
| Runtime building blocks | `vibeguard-runtime/src/git_root.rs`, `vibeguard-runtime/src/log_append.rs`, `vibeguard-runtime/src/circuit_breaker.rs`, `vibeguard-runtime/src/hook_checks_write.rs`, `vibeguard-runtime/src/hook_checks_bash.rs`, `vibeguard-runtime/src/hook_output.rs`, `vibeguard-runtime/src/main.rs` | Already implement git-root lookup, locked JSONL append, breaker state, per-hook checks, output rendering as separate subcommands | The pieces exist; they are only missing a single-call orchestration entry |
| Perf gates | `tests/bench_hook_latency.sh`, `tests/test_hook_perf_contract.sh` | Measure per-hook latency and enforce budgets in CI | Proof surface for this change |

## Proposed Design

Add one orchestrating subcommand per migrated hook to `vibeguard-runtime`:

```
vibeguard-runtime hook <name> [--config-overrides ...] < hook-stdin
```

For example `vibeguard-runtime hook pre-write` performs, inside one process:

1. Read and validate hook stdin (existing `pre-write-check` logic).
2. Resolve project root and project hash once (reuse `git_root.rs`; hash with
   a Rust SHA-256 instead of forking `shasum`).
3. Infer CLI + session id (port the `log_session.sh` ancestor walk using one
   `sysinfo`-style process read or a single `ps` spawn, then the same
   30-minute session-file protocol).
4. Evaluate the guard decision, including circuit-breaker read/update via
   `circuit_breaker.rs` with the same state files and fail-closed rules.
5. Append the event to project and global `events.jsonl` via `log_append.rs`
   in-process (no second exec), computing `duration_ms` natively.
6. Print the decision JSON / `hook-context` payload on stdout with the exact
   strings the bash implementation emits today.

The bash hook script body shrinks to: resolve runtime binary, `exec`
`vibeguard-runtime hook <name>`. `hooks/log.sh` keeps its resolution logic but
orders release before debug, and retains the full bash path only as the
documented fallback for unmigrated hooks.

Environment contract: the runtime reads the same env vars the bash layer
exports today (`VIBEGUARD_LOG_DIR`, `VIBEGUARD_LOG_FILE`,
`VIBEGUARD_PROJECT_LOG_DIR`, `VIBEGUARD_SESSION_ID`, `VIBEGUARD_CLI`,
`VIBEGUARD_POLICY_ENFORCEMENT`, caller-identity fields) and honors explicit
overrides before computing anything itself, so benchmarks and the app-server
wrapper keep their isolation behavior.

Migration order (one PR per hook, each benchmarked): `pre-write-guard`
(556ms) → `stop-guard` (331ms) → `pre-bash-guard` (224ms) → `learn-evaluator`
→ `pre-edit-guard` → `post-edit-guard` / `post-write-guard`.

## Product-to-Test Mapping

| Product invariant | Implementation area | Verification |
| --- | --- | --- |
| P1 decision byte-compat | `vibeguard-runtime/src/hook_output.rs` + per-hook orchestrator | Golden fixture diff: same stdin through old bash path and new runtime path, assert identical stdout/exit code (new test in `tests/hooks/`) |
| P2 event-log fields | `vibeguard-runtime/src/log_append.rs`, event schema | `tests/test_observability_schemas.sh` + field-by-field comparison in golden test |
| P3 breaker semantics | `vibeguard-runtime/src/circuit_breaker.rs` | Existing breaker cases in `tests/test_hooks.sh` run against migrated hook |
| P4 session grouping | session port in runtime | Unit tests for ancestor-walk parsing + 30-minute window reuse |
| P5 latency budget / single spawn | thin wrapper + orchestrator | `tests/bench_hook_latency.sh`, `tests/test_hook_perf_contract.sh`, CI P95 trend |
| P6 fail-closed | wrapper + orchestrator error paths | Kill/corrupt runtime binary in test, assert block output |
| P7 release-before-debug | `hooks/log.sh` resolution order | Unit test on resolution order with both binaries present |

## Data Flow

Input: hook stdin JSON (tool_name, tool_input, session metadata) plus
environment overrides. Persistence: `~/.vibeguard/projects/<hash>/events.jsonl`,
global `~/.vibeguard/events.jsonl`, breaker state files, session files —
all unchanged paths and formats. Output: decision JSON or advisory text on
stdout, diagnostics on stderr. External calls collapse from dozens of forks
to at most one `ps` spawn (session inference cold path) per invocation.

## Alternatives Considered

- Incremental bash optimization only (cache project hash + session id, use
  `$EPOCHREALTIME`, merge the two `append-jsonl` calls, inline the JSON field
  builders): recovers maybe half the overhead but keeps ~20 forks and two
  divergent logging implementations. Kept as fallback if the runtime port
  stalls, and the binary-resolution-order fix is worth doing regardless.
- Long-running daemon that hooks talk to over a socket: best latency ceiling
  but adds lifecycle, staleness, and security surface (SEC-13 concerns) that
  a single short-lived process avoids. Rejected for now.
- Rewriting wrappers to skip `run-hook.sh`: rejected; the wrapper carries the
  policy-profile and installed-snapshot contract.

## Risks

- Security: log/lock file handling moves fully into Rust; must keep 600/700
  permission calls and locked appends to avoid cross-session corruption.
  No new network or exec surface is added.
- Compatibility: decision strings are load-bearing (agents parse them, tests
  assert them). Golden-fixture parity tests gate each hook migration.
  Windows CI must keep passing (`ps` walk is macOS/Linux; Windows keeps the
  existing fallback attribution).
- Performance: a regression here is self-detecting via the existing CI
  benchmark budget gate; each migration PR compares against recent-main
  trend, not one baseline sample.
- Maintenance: transitional period has both bash and Rust logging paths;
  bounded by migrating hook-by-hook and deleting each bash path as its hook
  lands (no long-lived aliases, per U-24).

## Test Plan

- [ ] Unit tests: runtime orchestrator per hook (decision matrix, breaker
      transitions, session reuse window, malformed input) in
      `vibeguard-runtime/tests/`.
- [ ] Integration tests: golden parity fixtures old-vs-new through
      `hooks/run-hook.sh`; existing `tests/test_hooks.sh` suite unchanged.
- [ ] Manual verification: `tests/bench_hook_latency.sh` before/after per
      migrated hook; one live Claude Code session exercising Write/Bash/Stop
      with `~/.vibeguard/events.jsonl` inspected for schema and session
      continuity.

## Rollback Plan

Each hook migrates in its own commit/PR. Rollback for hook X is reverting its
commit: the bash body returns and the runtime subcommand becomes dormant
(unknown-subcommand callers do not exist anymore). No data migration occurs;
log, breaker, and session file formats are unchanged, so old and new paths
interoperate during partial rollout.
