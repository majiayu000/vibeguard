# Task Plan

## Linked Issue

GH-541

## Spec Packet

- Product: `product.md`
- Tech: `tech.md`

## Implementation Tasks

- [ ] `SP541-T1` Owner: agent — Curate the compact always-on core (L1-L7 summary + security/verification/core rules) as the default Claude injection surface, mirroring the Codex compact path. Done when: a defined compact core exists and lists its always-on members. Verify: review the core against a checklist of security/verification rule IDs.
- [ ] `SP541-T2` Owner: agent — Change `scripts/setup/targets/claude-home.sh` so the default profile installs the compact core, keeping full `rules/claude-rules/<lang>/` files installed but not front-injected. Done when: default install injects compact core only. Verify: inspect `~/.claude/rules/vibeguard/` after a default install.
- [ ] `SP541-T3` Owner: agent — Add path-scoped rule loading (or a reference-pull mechanism) so language rules load on matching file context. Done when: editing a `.rs` file surfaces Rust rules without front-loading them globally. Verify: scoped-load test on `.rs` vs `.py` context.
- [ ] `SP541-T4` Owner: agent — Gate full-set injection behind the `strict` profile in `hooks/manifest.json`/setup. Done when: `strict` loads the full set, default does not. Verify: install both profiles, compare payloads.
- [ ] `SP541-T5` Owner: agent — Add a test asserting `count_active_constraints.sh` on the default payload is within U-32 budget. Done when: default payload does not hit the block threshold. Verify: run `bash hooks/count_active_constraints.sh` against default payload.
- [ ] `SP541-T6` Owner: human — Approve the compact-core membership (which rules are always-on) and the default-vs-strict boundary. Done when: maintainer approves the core list. Verify: PR review approval recorded.

## Parallelization

T1 defines the core that T2/T4 consume, so T1 lands first. T3 (scoped loading) is independent of T2 but both edit the claude-home target — single owner. T5 depends on T2/T4 landing. T6 gates merge.

## Verification

- Run `bash hooks/count_active_constraints.sh` on the default payload; confirm within U-32 budget.
- Manual: default profile shows compact core; `strict` profile shows full set; `.rs` edit surfaces Rust rules.

## Handoff Notes

The always-on core must not drop security or verification rules — mis-scoping here is a real regression. Keep the compact core in sync with canonical rule text via the existing doc-generation pipeline rather than hand-maintaining a divergent copy. This fixes the self-violation without deleting any rule.
