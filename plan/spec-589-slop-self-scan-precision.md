# SPEC: check_code_slop self-scan precision — CLI stdout and detector-source FPs (#589)

**Status**: Draft v1
**Closes**: #589 (P2, guard, false positive)
**Depends on**: nothing

---

## Problem

`guards/universal/check_code_slop.sh` already auto-detects a self-scan of the vibeguard repo and excludes `workflows data scripts eval` (`guards/universal/check_code_slop.sh:83`), but two FP classes survive and dominate the weekly GC digest for this repo (~327 reported issues, majority FP):

1. **CLI stdout counted as debug leftovers** — the debug-code regex (`check_code_slop.sh:111`) flags every Rust `println!`. `vibeguard-runtime` is a CLI whose product surface *is* stdout (`vibeguard-runtime/src/setup_manifest.rs`, `vibeguard-runtime/src/json_field.rs`, …): 248 hits.
2. **Detector pattern strings counted as findings** — `vibeguard-runtime/src/hook_checks_write.rs:189-199` embeds `todo!(` / `unimplemented!(` as detection regex source and is flagged under "dead code markers".

A guard whose self-report is ~75% noise degrades the real signal (U-29) and makes the GC summary unusable for this repo.

## Goals

1. Self-scan of the vibeguard repo no longer flags legitimate CLI stdout or detector pattern sources.
2. Precision improvement is generic where cheap (Rust debug heuristic), repo-scoped where not (detector sources).
3. `--strict-repo` continues to disable every self-exclusion (existing contract, `check_code_slop.sh:29,47-48`).

## Non-goals

- No change to non-Rust debug detection (console.log / print) semantics.
- No allowlist mechanism for arbitrary third-party repos beyond the existing marker-file auto-detect.
- Not re-tuning the other slop categories (empty catch, stale TODO, long files).

## Behavior invariants

| ID | Invariant |
|---|---|
| B-001 | For Rust files, the debug heuristic flags `dbg!(` and `todo!`-style macros but not `println!`/`eprintln!` in crates under a `src/bin` or binary-crate layout; at minimum, self-scan excludes `vibeguard-runtime` from the `println!` branch. |
| B-002 | Self-scan (marker-file auto-detect true) does not report findings from files matching a documented detector-source list (initially `vibeguard-runtime/src/hook_checks_write.rs`), or from lines carrying an inline `// slop-pattern-source` marker. |
| B-003 | `--strict-repo` restores the current (noisy) behavior exactly. |
| B-004 | Non-self-scan targets (arbitrary user repos) see no behavior change except the Rust `println!` decision from B-001 if implemented generically; if repo-scoped, zero change. |
| B-005 | Self-scan of this repo after the fix reports the debug-code category at < 20 findings (down from 248) with no loss of true positives in `tests/` fixtures. |

## Design

Two small edits in `guards/universal/check_code_slop.sh`:

1. **Rust debug branch split** (B-001): run the existing regex for non-Rust includes unchanged; for `--include='*.rs'` use a Rust-specific pattern without `println!(`/`print(` (keep `dbg!(`). Rationale: in Rust, `dbg!` is the debug macro; `println!` is regular stdout and already covered by TASTE/RS lint layers where inappropriate.
2. **Detector-source exclusion** (B-002): extend the existing self-detect block (`check_code_slop.sh:76-84`) with a per-file exclusion list plus an inline-marker grep-v (`slop-pattern-source`), applied only when the marker-file auto-detect is true and `--strict-repo` is false.

Decision point for reviewer: B-001 generic (all Rust repos) vs repo-scoped (self-scan only). Spec recommends **generic** — flagging every `println!` in any Rust CLI is the same FP class everywhere, and `dbg!`-only matches the "legacy debugging code" intent.

## Product-to-test mapping

| Behavior invariant | Implementation area | Verification |
|---|---|---|
| B-001 | debug-code grep branch, `check_code_slop.sh:109-115` | fixture Rust file with `println!` + `dbg!` → only `dbg!` reported (new test file test_check_code_slop.sh under `tests/`, following the `tests/test_guard_packs.sh` pattern) |
| B-002 | self-detect block `:76-84` | self-scan run in tests asserts zero findings from `hook_checks_write.rs` |
| B-003 | flag plumbing `:40-48` | `--strict-repo` run asserts the fixture `println!` IS reported |
| B-005 | end-to-end | `bash guards/universal/check_code_slop.sh .` in CI: assert debug-code count < 20 (guard against future regression) |

## Verification plan

- New/extended guard test file under `tests/` runs in existing CI guard-validation leg.
- Manual before/after: `bash guards/universal/check_code_slop.sh .` — expect total to drop from ~327 to the true-positive core (stale TODOs, long files).

## Rollback

Single-file script change + tests; revert one commit. `--strict-repo` already provides a runtime escape hatch without rollback.
