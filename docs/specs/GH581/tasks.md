# Task Plan

## Linked Issue

GH-581

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP581-T1` Owner: agent — Capture a clean latest-head coverage inventory before each tranche and build the exhaustive critical-path inventory for that risk surface. Done when: evidence records the head SHA, pinned Rust/llvm-cov versions, total/covered lines, target-file coverage, current blocking baseline, and every in-scope critical scenario/path with exact `file:line` plus expected behavior. Verify: `bash scripts/ci/self-application/check-u22-coverage.sh`, full llvm-cov JSON, source audit, and reviewer completeness check.
- [ ] `SP581-T2` Owner: agent — Add behavioral coverage for `pre-bash` fail-closed orchestration without changing production semantics. Done when: malformed/missing command, deny/block, child nonzero, spawn/runtime/log failures, explicit skip branches, warn/correction/pass paths are asserted; every T1 critical inventory row is `covered` in full JSON or has a line-specific exception; clean coverage crosses from the recorded 67.x before floor to at least 68.x; and the blocking baseline rises from 66 directly to the post clean integer floor (at least 68), without counting pre-existing headroom as test progress. Verify: focused `cli_hook_orchestrator` tests, full Rust suite, before/post full JSON and summary evidence, exhaustive disposition, coverage gate, and baseline contract test.
- [ ] `SP581-T3` Owner: agent — Cover remaining high-risk hook checks and post-edit/history paths. Depends on: T2. Done when: malformed input, missing file/dependency, logging/history errors and fallback visibility have behavior assertions, and the blocking baseline rises again. Verify: focused hook-check/orchestrator tests plus full Rust/coverage gates.
- [ ] `SP581-T4` Owner: agent — Cover runtime policy and Codex setup health error paths. Depends on: T3. Done when: invalid config, missing manifest/hook, strict verdict, permission/I/O and reachable platform branches are tested, and the blocking baseline rises again. Verify: focused runtime/setup tests plus full Rust/coverage gates.
- [ ] `SP581-T5` Owner: agent — Cover rendering, observability and remaining low-coverage modules in risk order. Depends on: T4. Done when: no-data, malformed-data, output failure and deterministic rendering behavior are asserted, the latest inventory has no unexplained critical gap, and the blocking baseline rises again. Verify: focused observe/setup tests plus full Rust/coverage gates.
- [ ] `SP581-T6` Owner: agent — Complete the long-tail coverage and enforce the final 80% threshold. Depends on: T5. Done when: total line coverage is at least 80%, `LINE_COVERAGE_BASELINE=80`, “target not yet enforced” messaging is removed, contract tests assert the 80% gate, the union of all critical-path inventories has no missing or undispositioned row, and all canonical checks pass. Verify: clean full llvm-cov JSON and summary, exhaustive disposition audit, coverage contract, Rust checks/tests and self-application CI suite.
- [ ] `SP581-T7` Owner: independent reviewer — Review every tranche's diff, test integrity, before/after evidence, ratchet value, critical-path inventory and exception ledger. Done when: the reviewer independently compares the PR-head source to full llvm-cov JSON, confirms every in-scope critical line is listed and dispositioned, reports no blocking finding, and explicitly accepts or rejects every line-specific platform/unreachable exception. Verify: recorded native reviewer-lane verdict anchored to the PR head SHA and coverage artifact digest.

## First Tranche Ownership

| Lane | Owner | Writable files |
| --- | --- | --- |
| Test writer | one implementation lane | `vibeguard-runtime/tests/cli_hook_orchestrator.rs`; private tests in `hook_orchestrator_pre_bash.rs` only if integration cannot reach the helper |
| Gate ratchet | integration owner | `scripts/ci/self-application/check-u22-coverage.sh`, `tests/test_u22_coverage.sh` |
| Independent review | read-only reviewer lane | none |
| Verification/integration | root coordinator | no concurrent shared-file writes |

## Stop Conditions

- Clean total coverage does not improve or the integer blocking baseline cannot rise.
- A test requires production behavior changes; split that bug fix into a separately reviewed scope.
- A critical path remains uncovered without a line-specific reviewer verdict.
- A test relies on process-global environment mutation, file exclusion, disabled coverage or weakened assertions.
- Writable ownership overlaps another active branch, worktree or lane.

## Verification

First tranche:

```bash
cargo test --manifest-path vibeguard-runtime/Cargo.toml --test cli_hook_orchestrator pre_bash
bash tests/test_u22_coverage.sh
```

Every implementation tranche before submission:

```bash
cargo fmt --manifest-path vibeguard-runtime/Cargo.toml -- --check
cargo clippy --manifest-path vibeguard-runtime/Cargo.toml --all-targets -- -D warnings
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
bash scripts/ci/self-application/check-u22-coverage.sh
bash scripts/ci/self-application/run-all.sh
bash tests/test_self_application_ci.sh
bash tests/test_release_workflow.sh
bash scripts/local-contract-check.sh --quick
git diff --check
```

## PR Slicing And Handoff

- Spec packet PR: docs only, `Refs #581`.
- T2–T5 implementation PRs: one risk surface per PR, each uses `Refs #581` and raises the baseline.
- T6 final PR: use a closing keyword only after 80% is enforced and T7 confirms the final exception ledger.
- A blocked tranche does not authorize skipping its risk surface; checkpoint it and continue only with an independent, non-overlapping tranche.
