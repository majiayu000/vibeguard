# Product Spec

## Linked Issue

GH-551

## User Problem

Every Claude Code / Codex tool call that passes through a VibeGuard hook pays
100-550ms of latency (CI P95 baseline: pre-write-guard 556ms, stop-guard
331ms, pre-bash-guard 224ms). Measurement shows the guard logic itself costs
~4ms inside `vibeguard-runtime`; the rest is bash-layer fork/exec overhead
(sourcing shared libs, `git rev-parse` + `shasum` project hashing, `ps`
ancestor walks for session inference, and dozens of command substitutions per
`vg_log` call). For an agent making hundreds of tool calls per session, this
adds tens of seconds of pure overhead and pressures the CI hook-latency
budget gate without buying any additional protection.

## Goals

- Reduce per-invocation hook latency so each configured hook completes in a
  small, stable budget dominated by real check work, not process spawning.
- Preserve every existing guard behavior, decision output, and event-log
  contract exactly (decision JSON shape, `events.jsonl` schema, dual
  project + global log writes, circuit-breaker semantics, session
  attribution fields).
- Keep the migration observable through the existing benchmark and perf
  contract gates.

## Non-Goals

- No changes to which rules fire, their thresholds, or their messages.
- No change to the hook registration surface (`~/.claude/settings.json`,
  `~/.codex/hooks.json`, wrapper entry points).
- No removal of the bash wrappers themselves; they remain as thin entry
  points for compatibility.
- No new configuration options beyond what migration strictly requires.

## Behavior Invariants

1. For each migrated hook, the decision output (pass / warn / block /
   escalate JSON, exit codes, `hook-context` advisory payloads) is
   byte-compatible with the current implementation for the same input.
2. Every migrated hook still appends the same event fields to both the
   project-scoped and global `events.jsonl` (schema_version, ts, session,
   hook, tool, decision, reason, detail, duration_ms, caller identity
   fields), and unknown callers remain `client: "unknown"`.
3. Circuit-breaker state transitions (CLOSED → OPEN → HALF-OPEN) and
   fail-closed behavior on state read/write errors are preserved.
4. Session attribution (same session id within a 30-minute window per parent
   CLI process) produces the same grouping as today for Claude and Codex
   parents.
5. Hook latency for migrated hooks stays within the per-hook CI budget, and
   the migrated hot path performs at most a small constant number of process
   spawns per invocation (target: one runtime invocation from the wrapper).
6. When `vibeguard-runtime` is missing or fails, hooks fail closed with an
   explicit block message, never silently pass.
7. Benchmark tooling resolves the release runtime binary in preference to a
   debug build, so reported latency reflects production behavior.

## Acceptance Criteria

- [ ] `tests/bench_hook_latency.sh` shows migrated hooks meeting their
      per-hook budgets with P95 reduced versus the current `bench-output.json`
      baseline, on the CI benchmark gate trend (not a single local sample).
- [ ] `tests/test_hooks.sh` and `tests/test_hook_perf_contract.sh` pass
      unchanged (no assertion weakening).
- [ ] Event-log lines produced by migrated hooks validate against the
      existing schema checks (`tests/test_observability_schemas.sh`).
- [ ] A side-by-side fixture run (same stdin) shows identical decision output
      between old and new paths for pass, warn, block, and escalation cases.

## Edge Cases

- Malformed or empty hook stdin must still produce the explicit MALFORMED
  block, not a crash or silent pass.
- Non-git working directories (project hash falls back to `global`).
- Concurrent hook invocations writing the same log file (lock semantics must
  hold across the runtime append path).
- Warn-mode policy downgrade (`VIBEGUARD_POLICY_ENFORCEMENT=warn`) must still
  rewrite block decisions to warn advisories.
- Hosts where only the installed release binary exists (no repo checkout) and
  dev machines where debug and release builds coexist.

## Rollout Notes

Migrate hook-by-hook (highest-latency first: pre-write, stop, pre-bash) so
each step is independently benchmarked and revertable. The bash wrappers stay
in place, so rollback for any hook is restoring its previous script body. No
user-facing configuration or reinstall is required beyond the normal
`setup.sh` refresh that ships updated hook snapshots.
