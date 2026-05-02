# SPEC: Codebase Audit Remediation (2026-05-01)

**Status**: Draft for review
**Author**: majiayu000
**Date**: 2026-05-01
**Closes**: codebase audit findings (see [`docs/internal/research/2026-05-01-codebase-audit.md`](../docs/internal/research/2026-05-01-codebase-audit.md))
**Depends on**: nothing (P0/P1 tasks); SPEC-96 prompt-contract schema (P3 manifest convergence reuses pattern)
**Blocks**: nothing

---

## Goal

Eliminate the cluster of self-violations VibeGuard exhibits against rules it ships (SEC-13, U-29, U-22, U-16, U-24, U-26, W-18) and harden the multi-language pipeline so Python/Rust drift can no longer ship in production undetected.

This SPEC is the actionable counterpart to the audit research file. It is structured by execution phase (P0 → P3) and by task. Each task uses the four-element format (Goal / Context / Constraints / Done-when) per `~/.claude/CLAUDE.md`.

## Non-goals

- Not rewriting passing systems. Verified items (atomic install, env-var convergence, SEC-12 nested-table cleanup, etc.) remain untouched.
- Not introducing a new rule. Every fix maps to an existing rule already in `rules/claude-rules/`.
- Not shipping the legacy `mcp-server/` prototype as a supported runtime surface. It is documented as legacy/deprecated; any future MCP reintroduction needs a separate install path and audit/hash baseline.
- Not refactoring well-tested modules (`vg-helper/src/session_metrics.rs` `#[cfg(test)]` block at lines 391-755 is fine).
- Not adding new dependencies. Every fix uses existing tools (bash, python3, serde_json, regex).

---

## Context (Facts)

### Audit summary

- 4 parallel opus agents (`architect`, `security-reviewer`, `code-reviewer`, `database-reviewer`) ran on 2026-05-01.
- 0 critical, 10 high, 14 medium, 11 low findings — full evidence in [`docs/internal/research/2026-05-01-codebase-audit.md`](../docs/internal/research/2026-05-01-codebase-audit.md).
- Cross-cutting verdict: VibeGuard's three highest-leverage issues are (a) self-applied SEC-13 dog-fooding on `setup.sh`, (b) collapsing parallel Python/Rust implementations of `session_metrics` and `pkg_rewrite`, and (c) introducing a single `hooks/manifest.json` source-of-truth.

### Self-violation map

| Rule | Findings violating it | Severity cluster |
|------|----------------------|------------------|
| SEC-13 | H2, M3, M11 | high — install path bypasses self-rule |
| U-29 | H1, H3, H7, M13 | high — silent degradation in prod paths |
| U-24 + U-29 | H4, M6 | high — Python/Rust parallel drift |
| U-26 | H10, M4, M8, M12 | medium — declaration-execution gaps |
| U-22 | M7 | medium — vg-helper modules at zero coverage |
| U-16 | M14 | medium — five files near 800-line ceiling |
| W-18 | H5 | high — eval is output-only |

### Constraints from project conventions

- `~/.claude/CLAUDE.md` and `rules/claude-rules/`: Fact/Inference/Suggestion separation with mandatory confidence labels; no AI-generated commit markers (`Co-Authored-By` is forbidden); commits use Lore-protocol trailers per U-21; DCO `Signed-off-by` mandatory.
- `bun` for Node; `uv` for Python; `cargo` for Rust; no `pip`/`npm`/`pnpm`/`yarn` in scripts (W-19 already enforces `pnpm` rewrite, but new scripts in this SPEC use `uv`/`bun` only).
- File size: 200-400 LOC typical, 800 hard ceiling (U-16). New scripts in this SPEC must stay under 200 LOC.
- All new tasks must include verification commands that finish in under 60 s (W-03 Nyquist rule).

---

## Constraints (must hold across all tasks)

### Forward-compatibility

1. No Python/Rust API breaks visible to external consumers. Internal helpers may change.
2. `~/.claude/settings.json` schema, `~/.codex/hooks.json` schema, and `events.jsonl` line shape stay backward-compatible. Adding fields is allowed; renaming or removing is not in this SPEC.
3. CI must remain green at every commit. No "I'll fix the test in the next commit" detours.

### Verification cadence

- Every task ends with a verification command (W-03 + W-16). The command must run in this session, not be cited from memory.
- Every task includes a rollback step.
- High-risk tasks (T2, T7, T9) require a one-PR-per-task discipline; the others may bundle when scoped to one subsystem.

### Self-application

- For each self-violation fix, also add a guard or CI check that prevents regression. The pattern is "fix the symptom + add a sentinel". This is a hard requirement — without the sentinel the fix decays.

### Exclusions

- Do not modify the four `vibeguard-*.sh` Codex shims (L11) — they are required by Codex's basename-based matcher; document the carve-out in `hooks/CLAUDE.md` instead (T11).
- Do not delete or wire `mcp-server/` in this remediation stream. It is now documented as a legacy, unsupported prototype; shipping it again requires a future SPEC.

---

## Phase plan

| Phase | Window | Tasks | Risk |
|-------|--------|-------|------|
| **P0** | This week | T1, T2, T3, T7 | High — fixes critical self-violations and silent-degradation paths |
| **P1** | Two weeks | T4, T5, T6, T8 | Medium — collapses Python/Rust drift, adds W-18 axes, GC concurrency |
| **P2** | One month | T9, T10, T11 | Medium — manifest convergence, settings safety, test split |
| **P3** | Ongoing | T12, T13, T14, low-priority items | Low — god-file split, CI self-applied dog-food, low findings |

Each task below has its own four-element block, fix sketch, and explicit verification command.

---

## Tasks

### P0 — Critical self-violations and silent paths

#### T1 · Fail-closed pre-commit timeout (H1)

- **Goal**: pre-commit-guard must not silently bypass build/lint checks when they exceed the timeout.
- **Context**: `hooks/pre-commit-guard.sh:244-245` and `:302` treat exit code 124 as success. Adversarial commit can push `cargo check`/`tsc` past 10 s and skip every gate.
- **Constraints**:
  - Default behavior is fail-closed (timeout → block).
  - Provide an env override `VIBEGUARD_PRECOMMIT_TIMEOUT_BEHAVIOR={block|warn}` for users with intentionally slow projects.
  - Always emit a `vg_log warn|block` event with `decision_type=timeout` so the skip is visible in `events.jsonl`.
- **Done-when**:
  - `bash hooks/pre-commit-guard.sh` against a synthetic command that sleeps 11 s exits non-zero by default.
  - With `VIBEGUARD_PRECOMMIT_TIMEOUT_BEHAVIOR=warn`, same input exits 0 but emits a `warn` event with `reason: "guard timeout"`.
  - `tests/test_hooks.sh` (or its split successor) covers both branches.
  - Verification: `bash tests/test_hooks.sh test_precommit_timeout` exits 0.

Fix sketch:
```bash
# hooks/pre-commit-guard.sh
output=$(run_with_timeout "$cmd" 2>&1) || code=$?
if [[ $code -eq 124 ]]; then
  vg_log "pre-commit-guard" "" "block" "guard timeout (>${TIMEOUT}s)" "$cmd"
  case "${VIBEGUARD_PRECOMMIT_TIMEOUT_BEHAVIOR:-block}" in
    warn) return 0 ;;
    *)    return 2 ;;
  esac
fi
```

Rollback: revert the file; no schema change.

#### T2 · SEC-13 self-application on setup high-context writes (H2)

- **Goal**: `setup.sh` must show a unified diff and require explicit confirmation before writing `~/.claude/settings.json` or `~/.claude/CLAUDE.md`, matching its own SEC-13 rule.
- **Context**: `scripts/setup/targets/claude-home.sh:118-138` writes both files without diff/baseline/confirmation. Same applies to `~/.codex/hooks.json` and `~/.codex/config.toml`.
- **Constraints**:
  - Default: print diff + prompt `[y/N]`.
  - `VIBEGUARD_SETUP_AUTO=1` or `--yes` skips the prompt (preserves single-command install ergonomics).
  - `--dry-run` prints diff and exits 0 without writing.
  - Diff is computed against the on-disk content; first-time install (file absent) shows full content as added lines.
- **Done-when**:
  - `bash setup.sh --dry-run` produces unified diff to stderr; no files modified.
  - Without `VIBEGUARD_SETUP_AUTO=1`, install pauses for `[y/N]`.
  - `bash setup.sh --check` (existing health check) reports SEC-13 self-test passes.
  - Verification: `bash tests/test_setup.sh test_sec13_diff` exits 0.

Fix sketch: extend `scripts/lib/settings_json.py` with a `--diff-only` mode and have `scripts/setup/targets/claude-home.sh` call it before `settings_upsert`. For `CLAUDE.md` injection, `scripts/lib/claude_md.py` already takes a target; add `--diff-only` there too.

Rollback: revert the helper and target script changes; the diff helper itself is additive and harmless to leave behind.

Self-application sentinel: add `scripts/ci/self-application/check-sec13-self-apply.sh` that greps `setup/targets/*.sh` for direct `>>` or `python3 ... write` to `~/.claude/CLAUDE.md` or `~/.claude/settings.json` without going through the diff-helper. Run from CI.

#### T3 · log.sh must not collapse vg-helper failures into empty strings (H3)

- **Goal**: callers of `vg_json_field` can distinguish "field absent / null / empty" from "vg-helper failed".
- **Context**: `hooks/log.sh:70,81-82,93,105` use `2>/dev/null || echo ""`. `pre-bash-guard.sh` then `[[ -z "$COMMAND" ]] && exit 0` lets dangerous commands through on parse failure.
- **Constraints**:
  - Backward-compat: existing callers that don't care about parse failure must continue to work.
  - New behavior: stderr from vg-helper is captured into `events.jsonl` at `warn` level for SEC-13 audit trail.
  - Add `vg_json_field_strict` variant that exits non-zero on parse failure; migrate `pre-bash-guard.sh` to it.
- **Done-when**:
  - Feeding `{"tool_input":` (truncated JSON) to `pre-bash-guard.sh` produces `events.jsonl` line with `decision: "warn", reason: "json parse failed"` and exits 2 (block, fail-closed).
  - Existing `vg_json_field` callers see no behavior change for valid JSON.
  - `vg-helper/tests/cli.rs` adds an integration test for the strict variant.
  - Verification: `bash tests/test_hooks.sh test_log_sh_strict_parse` exits 0.

Fix sketch:
```bash
# hooks/log.sh
vg_json_field_strict() {
  local field_path="$1"
  local err_file
  err_file=$(mktemp)
  local out
  if out=$("$_VG_HELPER" json-field "$field_path" 2>"$err_file"); then
    rm -f "$err_file"
    printf '%s\n' "$out"
    return 0
  fi
  vg_log "log.sh" "" "warn" "json-field parse failed: $(cat "$err_file" | head -c 200)" "$field_path"
  rm -f "$err_file"
  return 1
}
```

Rollback: revert `log.sh` + `pre-bash-guard.sh`; existing tolerant `vg_json_field` is unchanged.

#### T7 · Eliminate U-29 violations in `constraint-recommender.py` and `eval/run_eval.py` (H7)

- **Goal**: silent `except Exception: pass` paths replaced with error-level logs and explicit `skipped` semantics in eval.
- **Context**: `scripts/constraint-recommender.py:30,52,73`; `eval/run_eval.py:97-103`.
- **Constraints**:
  - `constraint-recommender.py`: parse failures must log to stderr at `error` level; the recommender continues but the user sees the issue.
  - `eval/run_eval.py`: API errors return `{"detected": null, "skipped": true, "error": ...}`; aggregator (lines 300-321) excludes `skipped: true` from accuracy denominator.
  - Re-raise once cumulative API failures exceed `EVAL_MAX_API_FAILURES` (default 5).
- **Done-when**:
  - `uv run python eval/run_eval.py --sample 10 --inject-api-errors=3` produces a report distinguishing 3 skipped / 7 evaluated.
  - `uv run python scripts/constraint-recommender.py /nonexistent` logs at error level on stderr.
  - Verification: `uv run python -m pytest scripts/test_constraint_recommender.py` exits 0 (new test file).

Rollback: revert both files; no schema change since `skipped` is an additive field.

---

### P1 — Drift collapse, W-18, GC concurrency

#### T4 · Collapse Python/Rust session_metrics into a single canonical implementation (H4)

- **Goal**: only one implementation of session-metrics emits LEARN signals.
- **Context**: at audit time, `vg-helper/src/session_metrics.rs` (canonical, 755 LOC) and `hooks/_lib/session_metrics.py` (212 LOC fallback) drifted in Signal-6 depth and top-3 truncation.
- **Constraints**:
  - **Decision**: delete the Python fallback. Setup must require cargo OR fail loudly with a one-line install hint (not a silent fallback).
  - Implementation note (2026-05-02): PR #146 removed runtime Python fallback use and PR #147 deleted the legacy Python implementation, with `VIBEGUARD_ALLOW_NO_HELPER=1` as the explicit degraded install escape hatch.
  - All hook entry points that import `hooks/_lib/session_metrics.py` switch to `vg-helper session-metrics` subcommand.
- **Done-when**:
  - `rg "from session_metrics import|import session_metrics"` in `hooks/` and `scripts/` returns zero hits.
  - `test ! -e hooks/_lib/session_metrics.py` exits 0.
  - `bash setup.sh --check` reports cargo as required, not optional.
  - Integration test in `vg-helper/tests/cli.rs` covers Signal 1-6 emission with a fixture from `tests/fixtures/session-metrics/`.
  - Verification: `cargo test --test cli session_metrics` exits 0; `bash tests/test_hooks.sh test_session_metrics_canonical` exits 0.

Fix sketch:
1. Search-replace runtime Python helper calls with `vg-helper session-metrics`.
2. Make setup build/install `vg-helper` by default and fail loudly on cargo/build errors.
3. Delete `hooks/_lib/session_metrics.py` once no runtime caller remains.

Alternative (if cargo-required is unacceptable): keep both implementations and add a CI diff test feeding the same fixture to both. Less preferred — drift will recur.

Rollback: revert the deprecation banner and the search-replace; Python file remains.

#### T5 · pkg_rewrite same treatment as T4 (M6)

- **Goal**: same as T4 for `pkg_rewrite`.
- **Context**: at audit time, `vg-helper/src/pkg_rewrite.rs:16` and `hooks/_lib/pkg_rewrite.py` (99 LOC) followed the same parallel-implementation pattern as session_metrics.
- **Constraints**: identical to T4. Bundled with T4 in the same PR if scoped together; otherwise separate.
- **Done-when**:
  - `rg "from pkg_rewrite import"` returns zero hits in non-test code.
  - `test ! -e hooks/_lib/pkg_rewrite.py` exits 0.
  - `cargo test --test cli pkg_rewrite` covers each translation branch (~20 cases).
  - Verification: `bash tests/test_hooks.sh test_pkg_rewrite_canonical` exits 0.

#### T6 · W-18 axis coverage in `eval/run_eval.py` (H5)

- **Goal**: eval reports calibration alongside accuracy; document axis-1/2 as vacuous (text-only completion).
- **Context**: `eval/run_eval.py:122-128` only does substring match; lines 300-321 compute SWS×FPR with no calibration. W-18 axis-3 is never optional when confidence is implied.
- **Constraints**:
  - Add a `confidence` field to the model prompt instruction (existing prompt format extended with one line).
  - Bucket by severity (`SEC-*` / `U-*` / `W-*`) and compute Expected Calibration Error (ECE) per bucket.
  - Document axis-1 (tool selection) as vacuous because run_eval is single-shot text completion. Add a comment to that effect.
  - Backward-compat: old result files without `confidence` are tolerated and excluded from ECE.
- **Done-when**:
  - `uv run python eval/run_eval.py --calibration` emits `ece` field per severity bucket in the result JSON.
  - `eval/samples.py` schema documents the new `confidence` field.
  - `docs/internal/benchmarks/` shows a baseline ECE for the current eval set.
  - Verification: `uv run python -m pytest eval/test_run_eval.py::test_calibration` exits 0.

Rollback: revert `run_eval.py`; old reports without `ece` continue to render.

#### T8 · GC log rewrite must be atomic and concurrency-safe (H6)

- **Goal**: `gc-logs.sh` cannot truncate-then-rewrite while a hook is appending.
- **Context**: `scripts/gc/gc-logs.sh:60-95` uses `open(..., 'w')` without flock or atomic rename; `hooks/log.sh:297` appends concurrently.
- **Constraints**:
  - Use `os.replace(tmp, log_file)` after writing kept lines to a temp file in the same directory.
  - Acquire `fcntl.flock(LOCK_EX)` on the log file before rewrite; release after replace.
  - If the file mtime changed between read and write (someone appended during processing), abort the rewrite and retry once.
  - Skip rewrite entirely if mtime is within 30 s of "now" (best-effort hint; flock is the real guarantee).
- **Done-when**:
  - Concurrent test: spawn 10 background appenders writing 100 lines each; run `gc-logs.sh`; verify final line count = original + 1000 (no loss).
  - `gc-logs.sh --dry-run` prints what would be archived without modifying.
  - Verification: `bash tests/test_gc_logs_concurrent.sh` exits 0 (new test).

Fix sketch:
```python
# scripts/gc/gc-logs.sh inline python (or extracted to scripts/lib/gc_logs.py)
import fcntl, os, tempfile
fd = os.open(log_file, os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    mtime_before = os.fstat(fd).st_mtime
    with os.fdopen(fd, 'r') as f:
        kept = [line for line in f if should_keep(line)]
    tmp = tempfile.NamedTemporaryFile(
        mode='w', dir=os.path.dirname(log_file), delete=False
    )
    tmp.writelines(kept)
    tmp.flush()
    os.fsync(tmp.fileno())
    tmp.close()
    if os.stat(log_file).st_mtime != mtime_before:
        os.unlink(tmp.name)
        return  # someone appended during processing; skip this run
    os.replace(tmp.name, log_file)
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
```

Rollback: revert the file; old non-atomic rewrite still works for single-user setups.

---

### P2 — Manifest convergence, settings safety, test split

#### T9 · `hooks/manifest.json` as single source of truth for hook registration (H10, M9)

- **Goal**: adding a hook is a 2-file change (script + manifest row), not a 7+-file change.
- **Context**: extension cost analysis in audit; current touchpoints listed in H10. `schemas/install-modules.json` exists but is CI-documentation only.
- **Constraints**:
  - New file: `hooks/manifest.json` with the schema:
    ```json
    {
      "version": 1,
      "hooks": [
        {
          "name": "pre-bash-guard",
          "matcher": "Bash",
          "phase": "PreToolUse",
          "claude_supported": true,
          "codex_supported": true,
          "decision_types": ["pass","warn","block","correction"],
          "profiles": ["minimal","core","full","strict"]
        }
      ]
    }
    ```
  - `~/.claude/settings.json` and `~/.codex/hooks.json` template entries are **generated** from the manifest, not maintained by hand.
  - `vibeguard-<name>.sh` Codex shims are also generated.
  - Add `scripts/ci/validate-hooks-manifest.sh` enforcing that every `hooks/*.sh` (excluding `_lib/`, `git/`, `vibeguard-*.sh` shims, and `run-hook*.sh` wrappers) has a manifest row, and vice versa.
  - Add `scripts/ci/check-codex-shim-consistency.sh` enforcing the shim list matches `manifest.codex_supported == true`.
- **Done-when**:
  - `bash scripts/ci/validate-hooks-manifest.sh` exits 0 on the current state with no manual fixups.
  - Adding a new hook (smoke test) by writing the script + a manifest row produces the correct `settings.json` entry, Codex shim, and `hooks/CLAUDE.md` table row via `bash scripts/setup/regenerate-hooks-from-manifest.sh`.
  - `hooks/CLAUDE.md` has its file-description table marked auto-generated between `<!-- vibeguard-start -->` / `<!-- vibeguard-end -->` markers (W-19 compliance).
  - Verification: `bash scripts/ci/validate-hooks-manifest.sh` + `bash scripts/setup/regenerate-hooks-from-manifest.sh --check` both exit 0.

Rollback: delete the manifest, the regenerator, and the CI checks; existing settings templates are still load-bearing because they were copied at the migration commit.

This is the highest-leverage refactor in the SPEC. It also fixes M9 (install-modules.json drift) by extending the same pattern to skill modules.

#### T10 · settings.json upsert protects user customizations (M11)

- **Goal**: VibeGuard install does not silently revert a user's `flock`-wrapped or `nohup`-wrapped hook command.
- **Context**: `scripts/lib/settings_json.py:140-180` rewrites `hook["command"]` on match without checking whether the existing command is a verbatim canonical form.
- **Constraints**:
  - Track the previous canonical command in `~/.vibeguard/install-state.json`.
  - On upsert, if the existing on-disk command does not match either (a) the previous canonical or (b) the new canonical, surface a diff and require `--force-overwrite` to proceed.
  - Add a `vibeguardManaged: true` marker to inserted entries; refuse to update entries lacking the marker (these are hand-edited).
- **Done-when**:
  - User scenario test: install once → manually edit hook command to add `flock` prefix → run install again → install pauses with diff and `[y/N]`.
  - With `--force-overwrite`, install proceeds.
  - Verification: `bash tests/test_setup.sh test_settings_user_customization` exits 0.

Rollback: revert `settings_json.py` and remove the `vibeguardManaged` marker from `install-state.json` schema (the field is additive and safe to leave behind).

#### T11 · Split `tests/test_hooks.sh` per hook + document Codex shim downgrade (H8, L11)

- **Goal**: U-22 mechanical check (matching `*.test.*` per source file) becomes meaningful for hooks; document `vibeguard-*.sh` carve-out.
- **Context**: `tests/test_hooks.sh` is 1575 LOC, 2× U-16 hard ceiling. Codex shims are required by Codex's basename-based matcher (not a U-24 violation, but undocumented).
- **Constraints**:
  - Split into `tests/hooks/test_<hook_name>.sh` files, one per hook.
  - Original `tests/test_hooks.sh` stays as a 50-line orchestrator that sources every per-hook test.
  - Promote shared fixtures to `tests/lib/hook_test_lib.sh`.
  - Each per-hook file must be under 400 LOC.
  - Add a `# U-32 downgrade` paragraph to `hooks/CLAUDE.md` documenting why the four Codex shims exist.
- **Done-when**:
  - `bash tests/test_hooks.sh` (orchestrator) exits 0 with the same coverage as before split.
  - `find tests/hooks -name 'test_*.sh' | xargs wc -l | sort -rn | head -1` shows max under 400.
  - `wc -l tests/test_hooks.sh` shows under 100.
  - Verification: `bash tests/test_hooks.sh` exits 0; `bash scripts/verify/check-test-file-sizes.sh` (new) exits 0.

Rollback: `git revert` the split commit; the orchestrator script can re-bundle by reverting source.

---

### P3 — God-file split, CI dog-food, low-priority

#### T12 · God-file split (M14)

- **Goal**: bring all U-16 violators below 300 LOC per file.
- **Files** (in priority order; each is a separate sub-task):
  1. `vg-helper/src/session_metrics.rs` (755 → 4 modules: `mod.rs` + `collect.rs` + `aggregate.rs` + `render.rs`).
  2. `hooks/post-edit-guard.sh` (493 → orchestrator + `hooks/_lib/detect_*.sh` per detector: unwrap, console, path, go_discard, oversize_diff, churn, w15_loop).
  3. `scripts/gc/gc-scheduled.sh` (463 → `gc-{discover,classify,evict,report}.sh` + 50-line orchestrator).
  4. `hooks/log.sh` (337 → `_lib/{session,json,log,timer}.sh`; existing hooks source `_lib/log.sh` with re-exports for backward compat).
  5. `hooks/post-write-guard.sh` (337 → orchestrator + `_lib/detect_duplicate.sh` + `_lib/detect_filename_collision.sh`).
- **Constraints**:
  - Behavior must not change. Add a regression test for each split before refactoring.
  - Each split lands in its own PR with a before/after diff test.
- **Done-when**:
  - Every listed file under 300 LOC after split.
  - `tests/test_hooks.sh` and `cargo test` pass without modification.
  - Verification per sub-task: `bash tests/hooks/test_<hook>.sh` exits 0.

#### T13 · CI dog-food self-applied SEC-13 / U-29 / U-22 (cross-cutting)

- **Goal**: every rule VibeGuard ships gets enforced on the VibeGuard repo by CI.
- **Context**: cross-cutting observation in audit. Without sentinels, fixes T1/T2/T3/T7 will decay over time.
- **Constraints**:
  - New directory `scripts/ci/self-application/` containing one script per rule:
    - `check-sec13-self-apply.sh` — greps `setup/targets/*.sh` for direct writes to `~/.claude/CLAUDE.md` / `~/.claude/settings.json` not going through the diff-helper.
    - `check-u29-no-pass.sh` — greps non-test Python for `except Exception:\s*pass` and similar silent-degradation patterns; allow-list documented exceptions.
    - `check-u22-coverage.sh` — runs `cargo llvm-cov` on `vg-helper`, fails if any source file has < 80% line coverage.
    - `check-w18-eval-axes.sh` — verifies `eval/run_eval.py` emits at minimum `accuracy` and `ece` fields per severity bucket.
    - `check-sec14-self.sh` — scans `rules/**/*.md` for SEC-14 forbidden phrases with allow-list for `rules/claude-rules/common/security.md` (which legitimately quotes attack strings).
  - All run from `.github/workflows/ci.yml` self-application job.
- **Done-when**:
  - `bash scripts/ci/self-application/run-all.sh` exits 0 on a clean tree.
  - Synthetic test: revert T1's fail-closed change → `check-u29-no-pass.sh` (or `check-precommit-failclosed.sh`) catches it.
  - Verification: `bash scripts/ci/self-application/run-all.sh` exits 0.

Rollback: delete the self-application directory; CI returns to its previous shape.

#### T14 · Low-priority cleanup (L1–L11)

Each item below was handled in the P3.4 cleanup stream or explicitly retained as an intentional compatibility boundary.

| Sub-task | Resolution | Verification / evidence |
|----------|------------|-------------------------|
| L1 | Implemented: `pre-bash-guard.sh` documents the package-correction argv contract and `check-pkg-correction-argv-only.sh` now guards Python-source and shell-eval regressions. | `bash scripts/ci/self-application/check-pkg-correction-argv-only.sh`; `bash tests/test_self_application_ci.sh` |
| L2 | Implemented: SEC-14 defensive examples in `rules/claude-rules/common/security.md` are documented as rule text, not MCP description surfaces. | `bash scripts/ci/self-application/check-sec14-mcp-descriptions.sh` |
| L3 | Implemented differently: heredoc stripping is now a linear parser instead of a regex plus timeout. | `VIBEGUARD_TEST_UPDATED_INPUT=1 bash tests/hooks/test_pre_bash_guard.sh` |
| L4 | Intentionally retained: Codex native hooks consume JSON `permissionDecision: "deny"` payloads while the wrapper exits 0 after emitting a valid payload; changing to exit 1 would turn an intentional deny into wrapper failure semantics. | `bash tests/test_codex_runtime.sh`; `hooks/run-hook-codex.sh` header documents the Codex contract |
| L5 | Implemented: session metrics emit `schema_version` and tests assert the field. | `(cd vg-helper && cargo test)` |
| L6 | Implemented: `paralysis-count` applies a 30-minute timestamp window while preserving legacy timestamp-less events. | `(cd vg-helper && cargo test)` |
| L7 | Implemented: session metrics time helpers use Rust `SystemTime` instead of shelling out to `/bin/date`. | `(cd vg-helper && cargo test)` |
| L8 | Implemented by narrowing schema/runtime contract: `skills-loader` remains an optional manual hook, not a registered disabled-hook enum value. | `bash tests/test_setup.sh`; `README.md` hook table |
| L9 | Implemented: install-state helpers fail visibly on unsupported state versions. | `bash tests/test_setup.sh` |
| L10 | Implemented: GC retention/threshold knobs are schema-backed and read via shared project config helpers. | `bash tests/test_gc_config.sh` |
| L11 | Implemented/documented: `vibeguard-*.sh` Codex shims are a namespacing compatibility boundary, not duplicate business logic. | `hooks/CLAUDE.md`; `README.md` Codex runtime notes |

---

## Risks and trade-offs

### Decision: delete Python fallback for vg-helper-replaced modules (T4, T5)

- **Risk**: users without cargo or with cargo build failures lose all hook functionality.
- **Mitigation**: setup.sh fails loudly with a one-line install hint (`Install cargo: curl https://sh.rustup.rs -sSf | sh`); `VIBEGUARD_ALLOW_NO_HELPER=1` enables an explicit degraded install that disables package rewrite/session-metrics instead of silently degrading to Python.
- **Alternative considered**: keep both implementations with CI diff test. Rejected because parallel implementations have already drifted twice (session_metrics, pkg_rewrite); cost of guaranteeing equivalence forever exceeds cost of a clean uninstall path.
- **Confidence**: medium. If cargo-required turns out to break a meaningful user segment (e.g. a Codex-only ChromeOS workflow), revert to keep-both with diff test.

### Decision: SEC-13 self-application defaults to interactive prompt (T2)

- **Risk**: scripts that run setup non-interactively (CI smoke tests, dotfiles installers) break unless they set `VIBEGUARD_SETUP_AUTO=1`.
- **Mitigation**: setup.sh detects non-tty stdin and prints a one-line note about the env var instead of hanging on prompt.
- **Alternative considered**: default to auto-yes with a warning. Rejected because SEC-13's text says "explicitly confirmed by the user" — a warning is not confirmation.

### Decision: hooks/manifest.json as load-bearing (T9)

- **Risk**: every hook addition now requires a manifest update; forgetting it means the hook is invisible.
- **Mitigation**: CI check `validate-hooks-manifest.sh` fires before merge.
- **Alternative considered**: keep templates hand-maintained with a CI consistency check. Rejected because the consistency check still requires touching multiple files; the manifest reduces it to one.
- **Confidence**: high. SPEC-96 already establishes the manifest-driven pattern in the prompt-contract domain; this generalizes it.

---

## Verification matrix (P0 done-when)

After P0 (T1, T2, T3, T7) lands, all these must hold:

```bash
# All P0 verification commands. Each must finish under 60 s (W-03 Nyquist).
bash tests/test_hooks.sh test_precommit_timeout
bash tests/test_setup.sh test_sec13_diff
bash tests/test_hooks.sh test_log_sh_strict_parse
uv run python -m pytest scripts/test_constraint_recommender.py
uv run python -m pytest eval/test_run_eval.py::test_skipped_semantics
bash scripts/ci/self-application/run-all.sh  # added in P3 T13 but the SEC-13 sentinel comes in P0 T2
```

Each command must exit 0 with output captured in this session (W-16: verification must come from this session, not memory).

---

## Out of scope (explicitly deferred)

- Shipping `mcp-server/` as a supported runtime surface (M12). Current state documents it as a legacy, unsupported prototype.
- Full historical cleanup of non-symlink retired skill directories (CFG-2 residual). Active Claude/Codex skill install, check, clean, and tracked retired symlink cleanup now use `schemas/install-modules.json` plus install-state; user-owned regular directories remain untouched.
- Full historical `events.jsonl` migration tooling (M4). New runtime events now carry `schema_version: 1`; backfilling old logs remains out of scope.
- Workflow-template W-18 axis-1/2 coverage for tool-using agents — eval/run_eval.py is single-shot text completion; if other eval harnesses (eval-harness skill?) emerge later, they need their own SPEC entry.
- vg-helper coverage automation (T13's `check-u22-coverage.sh`) requires `cargo-llvm-cov` install in CI — handled in T13.

---

## Acknowledged trade-offs vs CLAUDE.md

- **U-04 (do not add features not asked for)**: T9 (`hooks/manifest.json`) and T13 (CI self-application) are arguably new features. They are justified because their absence is a structural cause of multiple findings (H10, M9, all self-violations).
- **U-06 (no new dependencies)**: this SPEC adds zero new packages. `cargo-llvm-cov` (T13) is already a `cargo install` in CI.
- **W-17 (fewer smarter gates beat more mechanical gates)**: T13 adds 5 CI scripts. Each absorbs an existing rule's enforcement rather than introducing a new rule. They merge into one `run-all.sh` entry point so users see one gate, not five.

---

## Index of audit findings → SPEC tasks

| Finding | SPEC task |
|---------|-----------|
| H1 | T1 |
| H2 | T2 |
| H3 | T3 |
| H4 | T4 |
| H5 | T6 |
| H6 | T8 |
| H7 | T7 |
| H8 | T11 |
| H9 | P2.3 execution-plan step (Codex adapter extracted; guarded by `check-codex-wrapper-thin.sh`) |
| H10 | T9 |
| M1 | (P3 — log redaction; bundled with T13 SEC-10 dog-food) |
| M2 | (P3 — small fix; replace heredoc with `vg_json_output_kv`) |
| M3 | T13 (`check-hook-output-rewriting.sh`) |
| M4 | T9 + P3 follow-up (`event_schema.rs` constants and additive runtime `schema_version: 1`) |
| M5 | (P3 — `--strict` flag on `vg-helper json-field`; bundled with T11 split) |
| M6 | T5 |
| M7 | T13 (`check-u22-coverage.sh`) + add tests as separate small PRs |
| M8 | (P3 — wire `validate_contract` into install or delete schema) |
| M9 | T9 + P3 follow-up (hook manifest plus active skill links are now load-bearing) |
| M10 | (P3 — dual-write log consolidation) |
| M11 | T10 |
| M12 | P3.4 legacy documentation; shipping support remains out of scope |
| M13 | (P3 — `rm -f` safety; bundled into T11 install hardening) |
| M14 | T12 |
| L1–L11 | T14 |

---

## Acceptance

This SPEC is accepted when:

1. The remediation owner (TBD) checks each P0 task off in this file with a commit reference.
2. P0 verification matrix runs green on `main`.
3. P1 tasks are ticketed (one issue per task or a single tracking issue with sub-tasks).
4. P2/P3 are scheduled into the issue tracker with the same severity tags as in the audit.

Estimated total work: P0 ~3-5 days; P1 ~1 week; P2 ~2 weeks; P3 ongoing. Total ~4-6 weeks for full remediation including review.
