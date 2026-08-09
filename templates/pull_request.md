# Summary

Describe the user-visible outcome in 1-3 sentences.

## Linked Work

- Issue, if any:

## Verification

- [ ] Focused tests:
- [ ] Broader relevant checks:
- [ ] Screenshots or logs when user-visible:

## Review

- [ ] Concrete correctness, security, and regression findings are addressed.
- [ ] Review stopped at `Findings: 0` plus `PASS`.
- [ ] No more than two review rounds were initiated.
- [ ] Any remaining process-only decision is explicitly left to a human.

## Paired Prompt-Rule Evaluation

- [ ] This PR does not add or change a prompt-injected native rule.
- [ ] This PR adds or changes a prompt-injected native rule, and the paired-eval report is attached:
  - Candidate rule ID:
  - Report or artifact link:
  - Target delta and sample count:
  - Non-target delta and sample count:
  - Producer model ID:
  - Judge model ID:
  - Judge prompt digest:
  - Threshold calibration: while `calibrated: false`, attach the `inconclusive` report with both deltas, sample counts, and model evidence; do not claim `pass`.
  - Note: CI does not machine-verify these numbers against the attached report; the reviewer must cross-check them with the linked `report.json`.
- [ ] Exemption requested for non-prompt-injection changes only:
  - Reason:
  - Maintainer approval:

## Release Notes

- [ ] Changelog or release note needed.
- [ ] Not user-visible.
