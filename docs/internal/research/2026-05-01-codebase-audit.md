# Codebase Audit — 2026-05-01

**Audit date**: 2026-05-01
**Branch**: `feat/sec14-u33-rules`
**Auditor**: codebase-audit skill (4 parallel opus agents)
**Tech stack**: Shell (131 files) + Rust (`vibeguard-runtime`, 13 files / 1381 LOC) + Python (25 files) + Markdown rules
**Method**: Parallel agent isolation, Fact/Inference/Suggestion separation per W-11

This file is the **raw findings snapshot**. The actionable remediation plan with task-four-elements lives in [`plan/spec-codebase-audit-remediation.md`](../../../plan/spec-codebase-audit-remediation.md).

---

## Summary

| Severity | Count | Key areas |
|----------|-------|-----------|
| Critical | 0 | — |
| High | 10 | Self-violation of SEC-13/U-29; cross-language drift; god files; W-18 eval gap |
| Medium | 14 | Drift between Python/Rust implementations; cache contract; install schema drift; god files |
| Low | 8 | Latent risks, low-frequency drift, judgment calls |

**Cross-cutting verdict** (4-agent consensus): VibeGuard violates several rules it ships and enforces on others. The most leveraged fixes are (a) self-applied SEC-13 dog-fooding on `setup.sh`, (b) collapsing parallel Python/Rust implementations of `session_metrics` and `pkg_rewrite`, and (c) introducing a single `hooks/manifest.json` source-of-truth that turns 7+ touchpoint hook addition into a 2-file change.

---

## Methodology

Four agents launched in parallel, each `model="opus"`:

| # | Agent | Type | Scope |
|---|-------|------|-------|
| A1 | Architecture & code quality | `architect` | god files (U-16), declaration-execution gaps (U-26), aliases (U-24), test asymmetry, extension cost |
| A2 | Security & error handling | `security-reviewer` | SEC-01/03/10/12/13/14 self-application, U-29 silent degradation in Python helpers, hook fail modes |
| A3 | Multi-language pipeline integrity | `code-reviewer` | shell↔python↔rust contracts, vibeguard-runtime boundary, JSON field handling, eval W-18 axes |
| A4 | Config & install schema consistency | `database-reviewer` | install-modules.json vs reality, Claude/Codex symmetry, GC concurrency, settings drift |

Every finding below uses `[source: file:line]` evidence and a confidence label.

---

## High (10 findings)

### H1 · SEC-2 · pre-commit guard timeout silently passes (fail-open)

- **Severity**: high
- **Rule**: U-29 (silent degradation), SEC-04 (auth bypass class)
- **Facts**:
  - [source: `hooks/pre-commit-guard.sh:244-245`] `output=$(run_with_timeout "$cmd" 2>&1) || code=$?` followed by `[[ $code -eq 124 ]] && return 0`
  - [source: `hooks/pre-commit-guard.sh:302`] `if [[ $code -ne 0 && $code -ne 124 ]]` — code 124 (timeout) excluded from build-fail set
- **Inference (high)**: any commit that pushes `cargo check` / `tsc --noEmit` past 10 s skips every quality gate without surfacing the skip in the log. Adversarial: a deeply-recursive macro file or a slow CI runner silently bypasses build-fail enforcement.
- **Suggestion**: change to fail-closed (timeout → `exit 2` + `vg_log warn "guard timeout (block)"`). If fail-open is intentional, add `# SEC-13-FAIL-OPEN-REASON:` header comment + visible `vg_log warn` so users see the skip.
  - **Alternative**: extend `VIBEGUARD_PRECOMMIT_TIMEOUT` and document the trade-off.

### H2 · SEC-3 · setup script writes high-context files without diff (SEC-13 self-violation)

- **Severity**: high
- **Rule**: SEC-13 (high-context file integrity)
- **Facts**:
  - [source: `scripts/setup/targets/claude-home.sh:118-123`] `settings_upsert "${SETTINGS_FILE}" "${PROFILE}"` writes `~/.claude/settings.json` with no diff
  - [source: `scripts/setup/targets/claude-home.sh:130-138`] `python3 "${CLAUDE_MD_HELPER}" inject "${CLAUDE_DIR}/CLAUDE.md" ...` writes user's `~/.claude/CLAUDE.md` with no sha256 baseline, no `[y/N]` prompt
- **Inference (high)**: `rules/claude-rules/common/security.md:140-144` (the project's own SEC-13 definition) requires "high-context file changes must be shown as a diff and explicitly confirmed by the user". `setup.sh` exempts itself. Voluntary install does not satisfy SEC-13's text — the rule says diff is mandatory.
- **Suggestion**: add `--dry-run` mode that prints the planned unified diff; require `--yes` (or `VIBEGUARD_SETUP_AUTO=1`) for the actual write.
  - **Alternative**: emit unified diff to stderr and prompt `[y/N]` before each write.

### H3 · DATA-1 · log.sh swallows every vibeguard-runtime failure into an empty string

- **Severity**: high
- **Rule**: U-29
- **Facts**:
  - [source: `hooks/log.sh:70`] `"$_VIBEGUARD_RUNTIME" json-field "$field_path" 2>/dev/null || echo ""`
  - [source: `hooks/log.sh:81-82,93,105`] same pattern in Python fallback and `vg_json_two_fields`
  - [source: `vibeguard-runtime/src/main.rs:78`] vibeguard-runtime does `eprintln!("vibeguard-runtime error: {e}")` + `exit 1` on errors
  - [source: `vibeguard-runtime/tests/cli.rs:98-119`] confirms invalid JSON exits 1
- **Inference (high)**: when stdin contains malformed JSON, callers receive `""` indistinguishable from "field genuinely absent". `pre-bash-guard.sh` then short-circuits via `if [[ -z "$COMMAND" ]]; then exit 0` and lets dangerous commands through. Security-sensitive U-29 violation.
- **Suggestion**: propagate exit code; emit a sentinel like `__VG_PARSE_ERROR__` when parse fails; pipe stderr through `vg_log warn "$field_path parse failed"` for SEC-13 audit trail.
  - **Alternative**: callers explicitly check `$?` after every `vg_json_field` call.

### H4 · DATA-2 · session_metrics drift between Python fallback and Rust hot-path

- **Severity**: high
- **Rule**: U-24 (no aliases), U-29 (silent degradation)
- **Facts**:
  - [source: `vibeguard-runtime/src/session_metrics/mod.rs:1-2`] header claims "Replaces hooks/_lib/session_metrics.py"
  - [source: `hooks/_lib/session_metrics.py`] still 212 lines, complete
  - [source: historical `scripts/setup/install.sh:146`] runtime build failures previously fell back to Python instead of failing installation.
  - **Signal-6 divergence**: Python `:124-133` extracts `paralysis Nx` depth; Rust `:257-267` only emits count
  - **Top-3 truncation**: Python `:144-146` `repeat_rules[:3]`; Rust `:282-286` iterates entire HashMap, non-deterministic order
- **Inference (high)**: same `events.jsonl` produces different LEARN signals on different machines depending on whether cargo built. User thinks "fallback works", actually gets a different signal set.
- **Suggestion**: add a CI integration test feeding the same fixture to both binaries and diffing stdout.
  - **Alternative (preferred)**: delete the Python implementation; require cargo or fail install loudly. Aligns with U-24 (no aliases).

### H5 · DATA-5 · eval pipeline only validates output, no W-18 axes

- **Severity**: high
- **Rule**: W-18 (evaluations must validate path, not only output)
- **Facts**:
  - [source: `eval/run_eval.py:122-128`] sole detection check is substring matching `[RULE_ID]` in reply text
  - [source: `eval/run_eval.py:130-136`] result dict has `rule, severity, detected, response, description` — no tool calls (single-shot completion), no confidence
  - [source: `eval/run_eval.py:300-321`] Layer-2 score = SWS × FPR; no calibration measurement (ECE)
  - [source: `eval/run_eval.py:97-103`] `except Exception as e: return {"detected": False, "error": str(e), "response": ""}` — API failures conflated with genuine misses
- **Inference (high)**: VibeGuard's eval is itself an output-only test, which W-18 explicitly rejects for any judge that emits or implies a confidence value. A confidently-wrong rule miss looks identical to a genuine miss in the current report.
- **Suggestion**: ask the model to emit `confidence: low/medium/high` per finding; compute ECE per severity bucket. Distinguish API-skipped from genuinely-missed using `skipped: True`.

### H6 · CFG-5 · gc-logs.sh races with concurrent hook writes (no flock, no atomic rename)

- **Severity**: high
- **Rule**: data-loss class
- **Facts**:
  - [source: `scripts/gc/gc-logs.sh:60-95`] uses `open(log_file, 'w')` to truncate then write back — no flock, no temp+rename
  - [source: `hooks/log.sh:297`] hooks call `vg_log` which appends to the same file
  - [source: `com.vibeguard.gc.plist:13-19`] GC runs Sunday 03:00
- **Inference (medium)**: window is narrow (3am Sunday) but the race is real — any session writing during GC's truncate-then-rewrite loses data silently.
- **Suggestion**: use `os.replace(tmp, log_file)` for atomic swap + `fcntl.flock(LOCK_EX)`; or skip GC if file mtime within 30 s.

### H7 · SEC-7 · U-29 silent-degradation cluster in Python tooling

- **Severity**: high (in aggregate)
- **Rule**: U-29
- **Facts**:
  - [source: `scripts/constraint-recommender.py:30,52,73`] three `except Exception: pass` blocks silently swallow Cargo.toml / package.json / pyproject.toml read failures → claims framework absent → wrong recommendation
  - [source: `eval/run_eval.py:97-103`] API errors converted to `detected=False` (same root as H5)
- **Inference (high)**: VibeGuard's own U-29 rule directly violated in non-test code that ships in setup. The eval one corrupts layer-2 metrics on any network blip.
- **Suggestion**: log to stderr at `error` level; for run_eval, change `error` field semantics to `skipped: True` and have aggregator distinguish. Re-raise once a configurable threshold of errors is exceeded.

### H8 · ARCH-1 · `tests/test_hooks.sh` = 1575 lines (2× U-16 hard ceiling)

- **Severity**: high
- **Rule**: U-16 (file size), U-22 mechanical check
- **Facts**:
  - 1575 lines for one mega-fixture testing 13 distinct hooks
  - Next-largest test file is `tests/test_codex_runtime.sh` at 662 lines
- **Inference (high)**: U-22 mechanical check ("matching `*.test.*` file") fails by design — no `pre-bash-guard.test.sh` exists. Adding a hook does not trigger an obvious test-file requirement.
- **Suggestion**: split per hook into `tests/hooks/test_pre_bash_guard.sh`, `tests/hooks/test_post_edit_guard_basic.sh`, etc., with `tests/test_hooks.sh` becoming a 50-line orchestrator. Promote shared fixtures to `tests/lib/`.

### H9 · ARCH-3 · `run-hook-codex.sh` inlines 5 Python heredocs, bypassing `log.sh` shared helpers

- **Severity**: high
- **Rule**: layer violation
- **Facts**:
  - [source: `hooks/run-hook-codex.sh:50-56,60-69,81-117,123-132,140-161`] five `python3 -c` / `python3 - <<'PY'` blocks each implementing Codex envelope reshape
  - [source: `hooks/log.sh:69-107`] `vg_json_field` already provides vibeguard-runtime-first-with-Python-fallback abstraction
- **Inference (high)**: 167 LOC contains ~80 LOC of duplication; each heredoc is a fresh `python3` fork (~50 ms cold-start); JSON-escape bug must be fixed in five places.
- **Suggestion**: extract `hooks/_lib/codex_adapter.sh` providing `codex_pretool_deny`, `codex_pretool_warn`, `codex_posttool_block`. Wrapper collapses to ~30 lines.
  - **Alternative**: add a `vibeguard-runtime codex-adapt --event <name>` subcommand; eliminates Python dependency end-to-end.

### H10 · ARCH-9 · Adding a hook requires editing 7+ files (no central manifest)

- **Severity**: high
- **Rule**: extension cost
- **Facts** (paths required when adding a hook):
  1. hook script in `hooks/`
  2. `hooks/run-hook.sh` (implicit; routing)
  3. `~/.claude/settings.json` template entry
  4. `vibeguard-<name>.sh` Codex shim (if Codex-supported)
  5. `~/.codex/hooks.json` template entry
  6. `tests/test_hooks.sh` fixture
  7. `hooks/CLAUDE.md` row in the file-description table
  8. [source: `scripts/lib/codex_hooks_json.py:17-42`] `MANAGED_SPECS` hardcoded list
- **Inference (medium-high)**: 7+ touchpoints confirmed; CFG-2 corroborates that the existing `install-modules.json` is documentation only.
- **Suggestion**: introduce `hooks/manifest.json` (`name, matcher, claude, codex, decision_types`); generate both settings files, the Codex shim, and the CLAUDE.md table from it. Adding a hook becomes script + manifest row.

---

## Medium (14 findings)

### M1 · SEC-5 · events.jsonl logs full Bash commands without redaction

- **Severity**: medium
- **Rule**: SEC-10
- **Facts**:
  - [source: `hooks/log.sh:243-298`] `vg_log "pre-bash-guard" "Bash" "pass" "" "$COMMAND"` writes 200-char-truncated `$COMMAND`
  - `grep redact|secret` in `hooks/log.sh` returns no hits — no redaction layer
- **Inference (high)**: `curl -H "Authorization: Bearer sk-..."`, `ssh -i ~/.ssh/private.pem`, basic-auth credentials all land in `~/.vibeguard/events.jsonl` (mode 600). Local-user isolated, but accessible to stats aggregator and any reader of the file.
- **Suggestion**: add redaction pass for `(Authorization|Bearer|api[_-]?key|password|secret|token)\s*[:=]\s*\S+` → `***REDACTED***`.
  - **Alternative**: store full command only in per-project log; global keeps metadata only.

### M2 · SEC-9 · `${FILE_PATH}` interpolated into JSON heredoc without escaping

- **Severity**: medium
- **Rule**: SEC-03 (output escaping)
- **Facts**: [source: `hooks/pre-edit-guard.sh:127-132,138-145,162-167`] three `cat <<BLOCK_EOF { "decision": "block", "reason": "... ${FILE_PATH} ..." } BLOCK_EOF` blocks; `FILE_PATH` derived from `tool_input.file_path` JSON
- **Inference (medium)**: a path containing `"` or `\` produces invalid JSON; Codex `extract_payloads` (`vibeguard-runtime/src/codex_app_server_core.rs:190`) catches invalid payloads and could silently drop the payload → block degrades to pass → W-12 protection bypassed by naming a file `evil"; "; .py`.
- **Suggestion**: replace each heredoc with `vg_json_output_kv` (already implements escaping at `hooks/log.sh:317`).

### M3 · SEC-8 · No SEC-13 v2.1.121 self-test for `updatedToolOutput`

- **Severity**: medium
- **Rule**: SEC-13 (Hook output-rewriting surface)
- **Facts**: `grep -rn "updatedToolOutput" hooks/ scripts/` returns zero hits — repo currently does not violate, but no guard enforces the rule going forward
- **Inference (medium)**: SEC-13 extension explicitly says "unannotated tool-output rewriting must be flagged as a SEC-13 anomaly" — there is no flagger.
- **Suggestion**: add `scripts/ci/self-application/check-hook-output-rewriting.sh`: grep `updatedToolOutput` in `hooks/**/*.sh`; require a `# SEC-13-OUTPUT-REWRITE-REASON:` magic comment header.

### M4 · DATA-3 · No single source of truth for events.jsonl field names

- **Severity**: medium
- **Rule**: U-26 (declaration-execution gap)
- **Facts**:
  - [source: `hooks/log.sh:291`] writer assembles `"hook"`, `"tool"`, `"decision"`, `"reason"`, `"detail"`, `"duration_ms"`, `"cli"`, `"agent"`, `"ts"`, `"session"` as raw strings
  - [source: `vibeguard-runtime/src/log_query.rs:48,69,70,118,119,123`] reader hardcodes the same literals
  - [source: `vibeguard-runtime/src/session_metrics/mod.rs:127-304`] reader hardcodes literals
  - [source: `hooks/_lib/session_metrics.py:48-69`] Python reader uses literals
- **Inference (high)**: a typo in any one place (e.g. `decison`) is silently dropped by every reader's `unwrap_or("")` / `.get(k, "")`. No compile-time agreement.
- **Suggestion**: define `pub const HOOK: &str = "hook";` etc. in `vibeguard-runtime/src/event_schema.rs`, `pub use` across modules; add a CI grep counting key occurrences across files for the shell side.

### M5 · DATA-6 · `vibeguard-runtime json-field` collapses absent / empty / null to ""

- **Severity**: medium
- **Rule**: contract clarity
- **Facts**: [source: `vibeguard-runtime/src/json_field.rs:15-32`, tested at `tests/cli.rs:73-95`] missing field → `""`, `Null` → `""`, `String("")` → `""`
- **Inference (high)**: `pre-bash-guard.sh`'s `[[ -z "$COMMAND" ]]` cannot distinguish "JSON has no `tool_input.command` key" (probable injection or schema drift) from "user really sent `command:""`" — same handling.
- **Suggestion**: add `--strict` flag exiting 3 on missing-field; document the matrix in `json_field.rs` header.

### M6 · DATA-8 · pkg_rewrite same parallel-implementation pattern as session_metrics

- **Severity**: medium
- **Rule**: U-24, U-29
- **Facts**: `vibeguard-runtime/src/pkg_rewrite.rs:16` and `hooks/_lib/pkg_rewrite.py` (99 lines) both exist with the same "Replaces …" comment pattern
- **Inference (medium)**: structural pattern identical to H4; high probability of similar drift, not yet line-by-line verified
- **Suggestion**: same treatment as H4 — CI diff test or delete the Python.

### M7 · DATA-9 · vibeguard-runtime coverage well below U-22 80% on two modules

- **Severity**: medium
- **Rule**: U-22
- **Facts**:
  - [source: `vibeguard-runtime/tests/cli.rs`] 158 LOC integration tests; only `json-field` happy/sad paths covered; `pkg-rewrite`, `churn-count`, `warn-count`, `build-fails`, `paralysis-count` have **zero** integration tests
  - [source: `vibeguard-runtime/src/log_query.rs`] 131 LOC, **no `#[cfg(test)]` module**
  - [source: `vibeguard-runtime/src/pkg_rewrite.rs`] 195 LOC with ~20 regex branches in `try_npm`/`try_yarn`/`try_pip`, **no `#[cfg(test)]` module**
  - `session_metrics.rs:391-755` has 364 LOC of `#[cfg(test)]` (this module is well-tested)
- **Inference (high)**: log_query (4 public fns × 0 tests) and pkg_rewrite (~20 regex branches × 0 tests) are below the U-22 80% bar.
- **Suggestion**: add `#[cfg(test)]` blocks: minimum 4 tests in log_query, ~20 branch tests in pkg_rewrite. Run `cargo llvm-cov` first to set baseline.

### M8 · CFG-1 · `vibeguard-project.schema.json` is declared but never loaded at runtime

- **Severity**: medium
- **Rule**: U-26
- **Facts**:
  - [source: `scripts/lib/vibeguard_manifest.py:209-220`] `validate_contract` defined
  - [source: `.github/workflows/ci.yml:111,242`] called only from CI
  - `grep "vibeguard_manifest.py"` in `scripts/setup/` returns no matches except the lib import
- **Inference (high)**: a user with `disabled_hooks: ["typo"]` in `.vibeguard.json` gets no validation error; the file is silently ignored by every consumer. Pure declaration-execution gap.
- **Suggestion**: either delete the schema (U-26 cleanup) or wire `validate_contract` into `install.sh` and add per-hook `.vibeguard.json` reader.

### M9 · CFG-2 · install-modules.json modules diverge from actual installer paths

- **Severity**: medium
- **Rule**: schema drift
- **Facts**:
  - [source: `scripts/setup/targets/codex-home.sh:6-23`] hardcodes skill list `plan-flow fixflow optflow plan-mode auto-optimize` + `vibeguard agentsmd-audit trajectory-review`
  - [source: `schemas/install-modules.json:159-185`] manifest declares the same three names independently
  - [source: `scripts/setup/targets/claude-home.sh:9-11`] also installs `auto-optimize` to `~/.claude/skills/`, **not declared in any manifest module**
- **Inference (high)**: manifest is CI documentation only; installers ignore it. Adding a skill requires editing both manifest and installer; missing the manifest results in CI passing while user gets no install.
- **Suggestion**: make `install_claude_home_assets` and `install_codex_home_assets` iterate the manifest.

### M10 · CFG-4 · Dual-write to project + global events.jsonl creates duplicate state

- **Severity**: medium
- **Rule**: data-divergence
- **Facts**:
  - [source: `hooks/log.sh:297-305`] every event written to both `${VIBEGUARD_PROJECT_LOG_DIR}/events.jsonl` and `${VIBEGUARD_LOG_DIR}/events.jsonl`
  - [source: `scripts/gc/gc-logs.sh:33`] GC operates only on global file
  - [source: `scripts/gc/gc-scheduled.sh:138`] reads only project files
- **Inference (high)**: global gets compressed but project files keep accumulating; stats query against archive misses events that GC dropped from project files (or vice versa).
- **Suggestion**: replace dual-write with a single canonical file + symlink; or extend `gc-logs.sh` to recurse into `projects/*/events.jsonl`.

### M11 · CFG-6 · settings.json upsert silently overwrites user-customized hook commands

- **Severity**: medium
- **Rule**: SEC-13 self-application
- **Facts**:
  - [source: `scripts/lib/settings_json.py:140-180`] match by `matcher == matcher && script_name in cmd`, then mutate `hook["command"] = desired_command`
  - User customizations like `flock /tmp/foo bash ~/.vibeguard/run-hook.sh ...` are reverted on next install with no warning
- **Inference (medium)**: VibeGuard arguably "owns" its hook entries, but per its own SEC-13 the self-modification still requires diff review.
- **Suggestion**: hash-compare existing command against the previous canonical (stored in `install-state.json`); on mismatch, print diff and require `--force`.
  - **Alternative**: add `vibeguardManaged: true` marker; refuse to update entries lacking the marker.

### M12 · CFG-9 · `mcp-server/` exists in repo but installer doesn't wire it

- **Severity**: medium
- **Rule**: U-26 / unwired
- **Facts**:
  - [source: `mcp-server/dist/index.js:8-15`] declares `guard_check`, `compliance_report`, `metrics_collect` MCP tools
  - [source: `scripts/lib/settings_json.py:73-81`] only `_remove_legacy_mcp_server` exists; no `_install_mcp_server`
  - `scripts/setup/install.sh` and both target scripts contain no `mcpServers` insertion code
- **Inference (medium)**: either a deprecated artifact or a forgotten install path. Per SEC-12 alwaysLoad guidance, *not* auto-loading is correct, but the MCP server's purpose should be documented.
- **Suggestion**: mark `mcp-server/` as `legacy: deprecated` in README per U-32 downgrade path; or wire installation with SEC-12 hash baseline.

### M13 · CFG-10 · Rule install destructively `rm -f`s user customizations

- **Severity**: medium
- **Rule**: U-29, W-10 (destructive-action confirmation)
- **Facts**:
  - [source: `scripts/setup/targets/claude-home.sh:65-66`] `rm -f "$f"` on any non-symlink `*.md` in `${rules_dest}` before re-symlinking
  - [source: `scripts/setup/targets/claude-home.sh:87-93`] `rm -rf "${rules_dest}/${subdir}"` when narrowing `--languages` filter
- **Inference (high)**: a user who replaces a rule symlink with a manual copy (to disable one rule locally) loses changes silently on reinstall. Narrowing `--languages` from `rust,python` to `rust` deletes the entire `python/` rule subtree without confirmation.
- **Suggestion**: before `rm -f`, sha256-compare against source; on diff, error-log + abort with override instructions.

### M14 · ARCH · god files cluster (U-16)

| File | Lines | Responsibility overload |
|------|------|-----------|
| `vibeguard-runtime/src/session_metrics/mod.rs` | 755 | collect + aggregate + serialize + ISO-8601 parsing |
| `hooks/post-edit-guard.sh` | 493 | 7 detectors (unwrap / console / path / Go / diff / churn / W-15) |
| `scripts/gc/gc-scheduled.sh` | 463 | discover + classify + evict + report |
| `hooks/log.sh` | 337 | vg_log + JSON helpers + CLI detect (87 LOC ancestor walker) + timer |
| `hooks/post-write-guard.sh` | 337 | duplicate detection + filename collision check |

- **Inference (high)**: each is at or near the 800 ceiling with multiple distinct concerns
- **Suggestion**: see SPEC for per-file split plan.

---

## Low (8 findings)

| ID | Description | Source |
|----|-------------|--------|
| L1 (SEC-1) | `pre-bash-guard.sh:185-189` `python3 -c "..."` `$_PKG_CORRECTION` is currently safe (argv-isolated) but has refactor-drift risk | `hooks/pre-bash-guard.sh:185-189` |
| L2 (SEC-4) | No SEC-14 self-test on `rules/**/*.md` (the rule files contain attack strings as documentation; future scanner needs allow-list) | `rules/claude-rules/common/security.md:158-167` |
| L3 (SEC-6) | Heredoc-stripping regex `<<-?\s*[\"']?(\w+)[\"']?.*?\n\1` with `re.DOTALL` has ReDoS shape; no Python timeout wrap | `hooks/pre-bash-guard.sh:32-38` |
| L4 (SEC-10) | `run-hook-codex.sh` exits 0 on deny path (mildly inconsistent with shell convention; not exploitable) | `hooks/run-hook-codex.sh:80-93,134,161` |
| L5 (DATA-4) | `session_metrics.jsonl` lacks `schema_version` — future negative-set changes invalidate baseline silently | `vibeguard-runtime/src/session_metrics/mod.rs:316-360` |
| L6 (DATA-7) | `paralysis_count` ignores time gaps — overnight Reads count toward today's paralysis | `vibeguard-runtime/src/log_query.rs:117-128` |
| L7 (DATA-10) | `chrono_now` shells to `/bin/date` instead of using `SystemTime` | `vibeguard-runtime/src/session_metrics/mod.rs:380-389` |
| L8 (CFG-3) | `disabled_hooks` enum lists `skills-loader` but installer never registers it | `schemas/vibeguard-project.schema.json:38` |
| L9 (CFG-7) | `install-state.json` writes `version:1` but no migration code anywhere | `scripts/lib/install-state.sh:33-44` |
| L10 (CFG-11) | Retention windows (90d/7d/10MB/3mo) hardcoded; project schema's `additionalProperties:false` blocks user override | `scripts/gc/gc-{scheduled,logs}.sh` |
| L11 (ARCH-4) | `hooks/vibeguard-*.sh` shims (Codex namespace requirement) — judgment call, not U-24 violation; document in CLAUDE.md as U-32 downgrade | `hooks/vibeguard-{pre-bash-guard,stop-guard,learn-evaluator,post-build-check}.sh` |

---

## Cross-cutting observations

1. **Self-violation cluster** — VibeGuard violates rules it ships:
   - SEC-13 (H2): `setup.sh` rewrites `~/.claude/CLAUDE.md` and `~/.claude/settings.json` without diff
   - U-29 (H1, H3, H7): timeout fail-open, `2>/dev/null || echo ""` sentinel collapse, `except Exception: pass`
   - U-22 (M7): vibeguard-runtime `log_query.rs` and `pkg_rewrite.rs` have zero tests
   - U-16 (M14): five files at or near the 800-line ceiling
   - U-24 + U-29 (H4, M6): parallel Python+Rust implementations drift in production
   - U-26 (M4, M8, M12): event-schema literals scattered, project schema unwired, mcp-server orphaned
   - W-18 (H5): eval is output-only, no axis-1/2/3 coverage

   Recommendation: dog-food self-tests in CI under `scripts/ci/self-application/` so each rule is enforced on the repo that defines it.

2. **Parallel-implementation drift is a category** — `session_metrics`, `pkg_rewrite`, settings/hook helpers all show "Rust hot-path replaces Python, but Python kept as fallback" pattern. This guarantees long-tail divergence without a CI diff test. Either delete the Python (preferred) or treat them as load-bearing peers and diff-test in CI.

3. **Manifest as single source of truth is the highest-leverage refactor** — H10 (extension cost), CFG-1 (M8), CFG-2 (M9) all share one fix: make `schemas/install-modules.json` (and a new `hooks/manifest.json`) load-bearing instead of documentary. After this, four other findings become trivial follow-ups.

4. **Test structure is the canary** — `tests/test_hooks.sh` 1575 LOC and `vibeguard-runtime/tests/cli.rs` 158 LOC against 1223 source LOC are both shaped like "tests exist, mechanism doesn't deliver". Coverage measurement is a 5-minute task that should gate the next PR.

---

## Verified items (no issues found)

- vibeguard-runtime Rust prod code: only one `let _ =` (`session_metrics.rs:367` — best-effort metrics write, RS-10 acceptable). No `unsafe`, no `unwrap()` in non-test code.
- Hook env-var discipline (per `hooks/CLAUDE.md:51`): hooks consistently pass data via stdin, not argv.
- `serde_json` errors propagate via `?` (`json_field.rs:41`, `log_query.rs:28`) — no silent parse-failure-as-success.
- `set -euo pipefail` in every reviewed hook — protects against unset-variable injection.
- `printf '%q'` shell quoting consistently applied for `$build_root` / `$REPO_ROOT` in `pre-commit-guard.sh`.
- Codex `[mcp_servers.vibeguard.*]` cleanup correctly handles nested subtables (`scripts/lib/codex_config_toml.py:82-93`).
- `~/.vibeguard/` path convergence (U-11/U-13/U-14): all 8 consumers read `${VIBEGUARD_LOG_DIR:-${HOME}/.vibeguard}` consistently.
- Install snapshot uses `mktemp` + atomic `mv` + restore-on-failure (`install.sh:114-134`).
- Legacy hook removal is clean (`settings_json.py:84-113`).
- C0 control-byte stripping in `vg_log` correctly prevents JSONL corruption from terminal escape sequences.

---

## Audit artifacts

- Agent A1 (architect): `agentId: acba082699bc1a215`
- Agent A2 (security-reviewer): `agentId: a1de8490211860573`
- Agent A3 (code-reviewer): `agentId: a2f2ff5ef4e86c1fc`
- Agent A4 (database-reviewer): `agentId: a9138870a1b272161`

(IDs are session-local; cited here only for reproducibility within the same session.)
