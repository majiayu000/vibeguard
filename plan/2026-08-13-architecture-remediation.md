# Architecture Remediation Plan (2026-08-13)

Status: Active execution plan.
Owner: repository maintainer.
Scope: structural design debt identified in the 2026-08-13 design review. One
execution lane per phase; each phase is independently shippable and verified.

## Findings Being Remediated

| # | Finding | Severity |
|---|---------|----------|
| F1 | Duplicate rule implementations: standalone `guards/` grep scripts and Rust `hook_checks_*` implement the same rules (e.g. unwrap, console/print residue) with two divergent sources of truth | High |
| F2 | `vibeguard-runtime/src/` is a flat directory of 80 files; several files sit at 750–800 lines, split mechanically to satisfy U-16 instead of by responsibility; 16 `*_tests.rs` files live at top level wired via `#[path]` | High |
| F3 | Configuration surface: 276 distinct `VIBEGUARD_*`/`VG_*` environment variables plus config.json/profile/language axes, with no layered config module | High |
| F4 | Process artifacts tracked in git: four `artifacts/triage/issue-*.json` files (and `artifacts/` was not ignored); 40+ historical `docs/specs/GH*` packets on main | Medium |
| F5 | A second product (specrail) shared the repo root without a documented boundary — resolved upstream: the SpecRail control plane was fully retired and its files removed from main before this plan executed | Medium (resolved) |
| F6 | `pre-write-guard` P95 is 2065ms while other hooks are 200–400ms; latency contract exists but this hook exceeds interactive budget | Medium |
| F7 | README first screen leads with two unpublished install channels | Low |

## Phases

### Phase 1 — Repository hygiene (this session)

- `git rm --cached artifacts/triage/issue-{615,702,703,704}.json` (the tracked
  process artifacts; root `bench-output.json` was already ignored and
  untracked).
- Add `artifacts/` to `.gitignore` so future triage/log outputs stay local.
- Stop condition: no generated artifact remains tracked; no test or CI script
  loses a fixture it reads from git.
- Validation: `bash tests/test_hook_perf_contract.sh` (asserts absence),
  `git status`.

### Phase 2 — Runtime crate modularization (this session)

Convert flat `src/*.rs` name-prefix groups into directory modules, following
the existing precedent of `observe/`, `session_metrics/`, `setup_markdown/`.
Pure file moves — no logic changes, no file merging or splitting, so U-16
line counts are unchanged.

Mapping (module path `crate::hook_checks` etc. for group roots is unchanged;
most group root files become the mod-rs of their directory, except
`hook_checks` and `hook_orchestrator`, whose root files sit at 796/799 lines:
adding submodule declarations would cross the U-16 800-line limit, so their
mod-rs is a new declaration-only file that glob-re-exports the moved root
content from `checks.rs` / `dispatch.rs`, keeping external paths identical):

| Group | Old files | New location |
|-------|-----------|--------------|
| `hook_checks/` | `hook_checks.rs`, `hook_checks_{bash,common,history,js,scan,write,write_scan}.rs`, `hook_checks{,_write,_write_scan}_tests.rs` | `hook_checks/{checks,bash,common,history,js,scan,write,write_scan,tests,write_tests,write_scan_tests}.rs` + declaration-only `vibeguard-runtime/src/hook_checks/mod.rs` re-exporting `checks` |
| `hook_orchestrator/` | `hook_orchestrator.rs`, `hook_orchestrator_{context,learn,post_edit,post_edit_history,post_write,pre_bash,pre_edit,stop}.rs`, `hook_orchestrator_post_edit_history{,_unit}_tests.rs` | `hook_orchestrator/{dispatch,context,learn,post_edit,post_edit_history,post_write,pre_bash,pre_edit,stop,post_edit_history_tests,post_edit_history_unit_tests}.rs` + declaration-only `vibeguard-runtime/src/hook_orchestrator/mod.rs` re-exporting `dispatch` |
| `codex_app_server/` | `codex_app_server.rs`, `codex_app_server_{core,file_changes,hooks,policy,strategies}.rs`, `codex_app_server_{strategies,profile,missing_hook,scoped_suppression}_tests.rs` | `codex_app_server/{mod,core,file_changes,hooks,policy,strategies,strategies_tests,profile_tests,missing_hook_tests,scoped_suppression_tests}.rs` |
| `codex_hooks/` | `codex_hooks.rs`, `codex_hooks_{adapter,diag}.rs` | `codex_hooks/{mod,adapter,diag}.rs` |
| `hook_status/` | `hook_status.rs`, `hook_status_{render,tests}.rs` | `hook_status/{mod,render,tests}.rs` |
| `setup/` | `setup_{codex_config,codex_hooks,codex_hooks_health,gemini_hooks,install_state,lock_lifecycle,manifest,markdown,quarantine_inventory,support}.rs`, `setup_managed_tree_{io,remove,state,test_support}.rs`, `setup_markdown/` | `setup/{codex_config,codex_hooks,codex_hooks_health,gemini_hooks,install_state,lock_lifecycle,manifest,markdown,quarantine_inventory,support}.rs`, `setup/managed_tree_{io,remove,state,test_support}.rs`, `setup/markdown/` + new `vibeguard-runtime/src/setup/mod.rs` |
| `project_config/` | `project_config.rs`, `project_config_scoped_suppression.rs` | `project_config/{mod,scoped_suppression}.rs` |
| `runtime_config/` | `runtime_config.rs`, `runtime_config_validation{,_tests}.rs` | `runtime_config/{mod,validation,validation_tests}.rs` |
| `u16/` | `u16_{baseline,config}.rs`, `u16_baseline_tests.rs` | `u16/{baseline,config,baseline_tests}.rs` + new `vibeguard-runtime/src/u16/mod.rs` |
| `logging/` | `log_{append,query,scope}.rs` | `logging/{append,query,scope}.rs` + new `vibeguard-runtime/src/logging/mod.rs` |

Left standalone (single-file responsibilities): `active_constraints`,
`bench`, `bench_support`, `circuit_breaker`, `core_classifiers`,
`event_schema`, `gemini_hooks`, `git_root`, `hook_input_diag`, `hook_output`,
`json_field`, `pkg_rewrite`, `runtime_policy`, `time_utils`, `wrapper_env`;
pre-existing directory modules `observe/` and `session_metrics/` are
untouched, and the `hook_checks_tests` aggregation stays inside its group.

Known external references that must move in the same change:

- `scripts/ci/self-application/check-u29-no-silent-degrade.sh` (reads the
  pre-bash classifier and orchestrator sources, now
  `vibeguard-runtime/src/hook_checks/bash.rs` and
  `vibeguard-runtime/src/hook_orchestrator/pre_bash.rs`)
- `scripts/ci/self-application/check-pkg-correction-argv-only.sh` (same two)
- `scripts/ci/check-event-schema-literals.sh` (reads
  `vibeguard-runtime/src/logging/query.rs`)
- `tests/self_application/policy_sentinel_tests.sh`,
  `tests/self_application/package_correction_tests.sh`,
  `tests/unit/test_universal_check_code_slop.sh` (fixture repos replicate the
  real paths those CI checks read)
- `lib.rs` compiles a subset crate; it mirrors the new structure with inline
  `mod hook_checks { pub mod bash; pub mod common; }` declarations.

Stop conditions:

- Any behavior change beyond module paths.
- Any file merge/split (would change U-16 accounting).

Validation:

```bash
cargo build --release --manifest-path vibeguard-runtime/Cargo.toml
cargo test --release --manifest-path vibeguard-runtime/Cargo.toml
bash scripts/ci/self-application/check-u29-no-silent-degrade.sh
bash scripts/ci/self-application/check-pkg-correction-argv-only.sh
bash scripts/ci/check-event-schema-literals.sh
bash tests/self_application/policy_sentinel_tests.sh
bash tests/self_application/package_correction_tests.sh
```

#### Phase 2 commit-time note (resolved 2026-08-13)

The staged rename set initially tripped the pre-commit RS-03 unwrap/expect
check: per-file pathspec-limited diffs (`git diff --cached -- <new-path>`)
cannot pair a staged rename, so renamed files appeared as all-new `+` lines and
six pre-existing `.expect()`/pattern-string lines were reported as if newly
added. Root cause fixed in the same change set:

- `guards/rust/common.sh` gained a rename-aware `vg_staged_file_diff` helper;
  `guards/rust/check_unwrap_in_prod.sh` and `guards/rust/check_nested_locks.sh`
  use it.
- `guards/go/common.sh` and `guards/typescript/common.sh` linemap builders pair
  renames before diffing (staged and baseline modes).
- `hooks/pre-commit-guard.sh` passes an explicit `-M` for the shared
  added-lines baseline.
- Regression coverage: three rename cases in
  `tests/unit/test_baseline_scanning.sh` (pre-existing violation not reported,
  newly added violation still reported, linemap only holds edited lines).

### Phase 3 — Guard convergence into the runtime (issue #752)

Target: one rule engine. Each `guards/<lang>/check_*.sh` rule gets a runtime
implementation (`vibeguard-runtime scan <lang> <rule> <path>`), and the shell
script becomes a thin exec shim (same pattern the hooks already use). Rules
that need AST awareness move to the existing `ast-grep-rules/` surface instead
of new grep. Order by duplication risk: rules that already have a Rust twin
first (`unwrap`, console/print residue, stub detection), then single-source
shell rules. Behavior eval (`eval/run_behavior_eval.py`) is the gate: each
migrated rule needs a before/after fixture parity check.

### Phase 4 — Layered configuration module (issue #753)

Single `runtime_config` resolution order: defaults → `~/.vibeguard/config.json`
→ project config → environment. Publish a supported-variable allowlist in
`docs/rule-reference.md`; everything else becomes internal (`VG_INTERNAL_*`)
with a deprecation window. Add a `vibeguard-runtime config explain` command
that prints the resolved value and its source layer.

### Phase 5 — Docs and process-artifact policy (issue #754)

Archive closed `docs/specs/GH*` packets (git history is the archive; keep an
index), define which artifacts may ever be committed, and cut the number of
`CLAUDE.md` copies by generating directory guidance from one source.

### Phase 6 — specrail boundary decision (resolved upstream)

Upstream retired the SpecRail control plane and removed its workflow, state,
label, skill, and check files from main (see
`plan/2026-07-29-remove-mandatory-specrail-gates.md`), so no boundary
decision remains. Historical references live in `docs/specs/GH595/` under
allowlisted historical entries.

### Phase 7 — pre-write-guard latency (issue #755)

Profile the 2065ms P95 (`bench-output` shows 10x the budget of sibling hooks).
Likely cause: unindexed search-first scan on every new-file write. Candidate
fix: cache the project file inventory keyed by git HEAD + dirty-file mtimes.
