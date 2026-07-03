# Task Plan

## Linked Issue

GH-556

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP556-T1` Owner: agent — Define the health report schema and CLI contract. Done when: JSON keys, markdown sections, scope/window options and no-data/error behavior are documented in tests. Verify: CLI help and schema fixture test.
- [ ] `SP556-T2` Owner: agent — Add the thin report aggregator over existing observe summary/health data. Done when: report includes trigger counts and decision distribution for project and global scopes. Verify: fixture test plus `bash tests/test_stats.sh` and `bash tests/test_hook_health.sh`.
- [ ] `SP556-T3` Owner: agent — Integrate precision tracker data without mutating the scorecard by default. Done when: report includes precision, FP count, sample count, last FP and lifecycle stage per rule. Verify: fixture test plus `bash tests/test_precision_tracker.sh`.
- [ ] `SP556-T4` Owner: agent — Add unclassified backlog and schema-gap reporting. Done when: malformed or rule-id-missing triage candidates are visible and malformed JSONL fails loudly. Verify: focused malformed JSONL and missing-rule-id fixtures.
- [ ] `SP556-T5` Owner: agent — Add idle asset and downgrade candidate detection. Done when: 30-day zero-trigger rules and zero-use skills are listed as candidates with evidence, not automatically disabled. Verify: deterministic inventory fixture.
- [ ] `SP556-T6` Owner: agent — Surface the manual command through docs or an existing observe skill entry. Done when: a maintainer can run one command and find the output file path. Verify: doc path and command path validators.
- [ ] `SP556-T7` Owner: human — Validate the manual weekly report on a real incident window, especially W-13 after GH-554/GH-555 land. Done when: maintainer confirms the report catches the W-13 blind spot. Verify: PR review or issue comment.
- [ ] `SP556-T8` Owner: agent — Add opt-in weekly scheduling only after T7. Done when: launchd/cron wrapper writes a report file without installing by default. Verify: dry-run scheduler test and manual opt-in install test.

## Parallelization

T1 defines the shared schema, so it lands first. T2 and T3 can be implemented in parallel only if they touch disjoint adapters and tests. T4 depends on T3. T5 can proceed after T1 but must not share writable files with T2/T3 workers. T6 follows the command shape. T8 is blocked by the human validation gate T7.

## Verification

For the implementation PR, run:

```bash
python3 -m py_compile scripts/health-report.py
bash tests/test_stats.sh
bash tests/test_hook_health.sh
bash tests/test_precision_tracker.sh
bash tests/test_learn_adoption.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```

If the implementation changes runtime observe behavior, also run:

```bash
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml observe
```

## Handoff Notes

Do not add default automation before the manual report has been validated. The first implementation slice should prefer a manual report command and focused fixtures. Use `Refs #556` for partial slices; use a closing keyword only after the manual report, risk sections, idle asset detection and scheduling gate are all satisfied.
