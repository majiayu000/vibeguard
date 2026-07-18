# Tech Spec

## Linked Issue

GH-541

## Product Spec

See `product.md`.

## Codebase Context

| Area | Files | Current behavior | Why relevant |
| --- | --- | --- | --- |
| Rule count | `claude-md/vibeguard-rules.md:4` (`__VIBEGUARD_RULE_COUNT__`), `rules/claude-rules/**` (123 `## X-NN`) | ~126 rules defined | Scale of the payload |
| Claude injection | `~/.claude/rules/vibeguard/` (symlinked full set), `scripts/setup/targets/claude-home.sh` | Full text loaded per session | The over-injection site |
| Codex compact | `claude-md/vibeguard-rules.md` (L1-L7 + 16-row table) | ~82 lines, in budget | The model to emulate for the default |
| Self-check | `hooks/count_active_constraints.sh`, `scripts/constraints/count_active_constraints.py`, `vibeguard-runtime/src/active_constraints.rs` | Counts effective constraints | Must pass on the new default |
| Profiles | `hooks/manifest.json` (`claude.profiles`), setup | `strict` vs default profiles exist | Opt-in mechanism for full load |

## Proposed Design

Split rule delivery into a compact always-on core plus lazy, path-scoped rule files:

1. Author/curate a compact core (L1-L7 summary + the always-on security/verification/core rules) as the default injected surface — mirror what the Codex path already ships.
2. Keep the full `rules/claude-rules/<lang>/` files installed but not injected by default. Load them on demand keyed on the files a session touches (host permitting), or expose them via reference so the agent can pull them when relevant.
3. Gate full-set injection behind the `strict` profile in `manifest.json`/setup.
4. Ensure `count_active_constraints.sh` measures the default payload and stays within U-32.

## Product-to-Test Mapping

| Product invariant | Implementation area | Verification |
| --- | --- | --- |
| P1 compact default | claude-home install target | measure injected payload size/count |
| P2 always-on core present | compact core content | assert security/verification rules in default |
| P3 path-scoped load | rule loader / reference | test loads Rust rules only on `.rs` context |
| P4 strict opt-in | `manifest.json` profiles | strict profile still full-loads |
| P5 within budget | `count_active_constraints.sh` | run on default payload, no block |

## Data Flow

setup → writes compact core into `~/.claude/rules/vibeguard/` default surface; full rule files remain installed but not front-loaded. `count_active_constraints` reads the active payload. No new persistence.

## Alternatives Considered

- Trim the rule set to <30 rules total: rejected — loses coverage; the issue is delivery, not authorship.
- Keep full load, suppress the self-check: rejected — hides the violation instead of fixing it.

## Risks

- Security: must guarantee security-critical rules stay in the default core (regression risk if mis-scoped).
- Compatibility: users relying on full-load must move to `strict`; document clearly.
- Performance: smaller default payload should help agent compliance (the whole point of U-32).
- Maintenance: compact core must be kept in sync with canonical rules — reuse the existing doc-generation pipeline where possible.

## Test Plan

- [ ] Unit tests: `count_active_constraints.sh` on default payload within budget; strict profile full.
- [ ] Integration tests: path-scoped load surfaces language rules on matching edits.
- [ ] Manual verification: start a Claude session on default profile, confirm compact payload; switch to strict, confirm full.

## Rollback Plan

Revert the install target to symlink the full set by default; the `strict` profile and compact core remain available. No data migration.
