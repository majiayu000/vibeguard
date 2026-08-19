# VibeGuard Specs Index

`docs/specs/` holds the small set of maintained, cross-cutting design documents
that still explain current product contracts. It is not an execution queue.
New work requires an explicit current request or a freshly verified issue.

Closed issue-specific `GH*` packets are not kept in the current tree. Git
history is their archive; the outcome index below preserves discovery without
making historical packets look executable. `archived-issues.txt` is the
machine-readable completeness inventory checked against this table.

## Maintained Specs

| Spec | Status | Use it for |
|---|---|---|
| `codex-app-observability-plugin.md` | Implemented reference | Codex App plugin packaging, observability commands, and privacy boundaries |
| `install-friction-reduction.md` | Implemented reference | Prebuilt runtime binaries, release checksums, source fallback, and scheduler opt-in behavior |
| `learn-first-class-signal-inbox.md` | Implemented reference | Learn signal intake, classification, adoption, and outcome-evaluation design |
| `rust-only-production-path.md` | Implemented reference | Python-free production path, Rust runtime boundaries, and validation expectations |

## Archived GitHub Packet Index

| Issue | Outcome retained by current source/tests |
|---|---|
| [GH539](https://github.com/majiayu000/vibeguard/issues/539) | Claude wrapper fails closed on policy/config errors |
| [GH540](https://github.com/majiayu000/vibeguard/issues/540) | Manual precision-triage capture and scorecard feedback loop |
| [GH541](https://github.com/majiayu000/vibeguard/issues/541) | Compact default-profile rule injection within the U-32 budget |
| [GH542](https://github.com/majiayu000/vibeguard/issues/542) | Installed-snapshot drift reporting after source updates |
| [GH543](https://github.com/majiayu000/vibeguard/issues/543) | Symmetric cleanup of VibeGuard state and git-hook symlinks |
| [GH551](https://github.com/majiayu000/vibeguard/issues/551) | Hook hot-path consolidation into the Rust runtime |
| [GH556](https://github.com/majiayu000/vibeguard/issues/556) | Privacy-safe weekly health reporting and opt-in scheduling |
| [GH566](https://github.com/majiayu000/vibeguard/issues/566) | Detection and repair of unmanaged stale Codex hooks |
| [GH581](https://github.com/majiayu000/vibeguard/issues/581) | Measured Rust coverage ratchets and the enforced baseline |
| [GH588](https://github.com/majiayu000/vibeguard/issues/588) | Scheduled cleanup freshness and platform-correct log evidence |
| [GH589](https://github.com/majiayu000/vibeguard/issues/589) | Code-slop self-scan precision for Rust CLI output |
| [GH590](https://github.com/majiayu000/vibeguard/issues/590) | W-14 cooldown, bounded history, and suppression telemetry |
| [GH595](https://github.com/majiayu000/vibeguard/issues/595) | Retired SpecRail adoption and offline-gate design history |
| [GH605](https://github.com/majiayu000/vibeguard/issues/605) | Rust `*_tests.rs` classification for RS-03 precision |
| [GH608](https://github.com/majiayu000/vibeguard/issues/608) | Default repository resolution for standalone compliance checks |
| [GH611](https://github.com/majiayu000/vibeguard/issues/611) | Stable multi-sample hook latency gating |
| [GH614](https://github.com/majiayu000/vibeguard/issues/614) | macOS CI timeout headroom with blocking setup coverage |
| [GH615](https://github.com/majiayu000/vibeguard/issues/615) | Reminder-aware pre-write escalation and recovery guidance |
| [GH618](https://github.com/majiayu000/vibeguard/issues/618) | Manifest-driven compliance language scope and guard reporting |
| [GH621](https://github.com/majiayu000/vibeguard/issues/621) | Install-time runtime acquisition and provenance extraction |
| [GH623](https://github.com/majiayu000/vibeguard/issues/623) | Self-application CI decomposition into focused domains |
| [GH626](https://github.com/majiayu000/vibeguard/issues/626) | Canonical generation of compact injected rule guidance |
| [GH627](https://github.com/majiayu000/vibeguard/issues/627) | Codex namespaced hook resolution without alias scripts |
| [GH628](https://github.com/majiayu000/vibeguard/issues/628) | Personal-path detection and scoped documentation allowlists |
| [GH629](https://github.com/majiayu000/vibeguard/issues/629) | Schema-backed runtime configuration validation |
| [GH630](https://github.com/majiayu000/vibeguard/issues/630) | Pinned evaluation aliases and shared model resolution |
| [GH631](https://github.com/majiayu000/vibeguard/issues/631) | Distribution ownership and explicit orphan deletion |
| [GH632](https://github.com/majiayu000/vibeguard/issues/632) | Repository map and presentation metadata refresh |
| [GH644](https://github.com/majiayu000/vibeguard/issues/644) | Deterministic stdin and complete child-error evidence |
| [GH652](https://github.com/majiayu000/vibeguard/issues/652) | Deterministic current-source setup runtime pinning |
| [GH658](https://github.com/majiayu000/vibeguard/issues/658) | Work-surface classification before readiness routing |
| [GH659](https://github.com/majiayu000/vibeguard/issues/659) | Bounded logs and stale learning-marker reporting |
| [GH660](https://github.com/majiayu000/vibeguard/issues/660) | Retirement of obsolete strategic-compact guidance |
| [GH661](https://github.com/majiayu000/vibeguard/issues/661) | Wrapped-hook exit code and signal preservation |
| [GH671](https://github.com/majiayu000/vibeguard/issues/671) | Baseline-aware U-16 enforcement for changed files |
| [GH675](https://github.com/majiayu000/vibeguard/issues/675) | Manual precision-triage channel visibility |
| [GH686](https://github.com/majiayu000/vibeguard/issues/686) | Paired rule-target evaluation and regression evidence |
| [GH687](https://github.com/majiayu000/vibeguard/issues/687) | W-21 evidence provenance and W-01 channel trust |
| [GH699](https://github.com/majiayu000/vibeguard/issues/699) | Clone-free verified release payload installation |
| [GH700](https://github.com/majiayu000/vibeguard/issues/700) | Released-binary benchmark command and paired corpus |
| [GH701](https://github.com/majiayu000/vibeguard/issues/701) | Historical host-adapter roadmap; no adapter delivered |
| [GH702](https://github.com/majiayu000/vibeguard/issues/702) | Historical guard-pack roadmap; no publish/install surface delivered |
| [GH703](https://github.com/majiayu000/vibeguard/issues/703) | Weekly value summaries and explicit share exports |
| [GH704](https://github.com/majiayu000/vibeguard/issues/704) | Historical L2 semantic-defense research; no model runtime delivered |
| [GH706](https://github.com/majiayu000/vibeguard/issues/706) | Malformed-input diagnostics and protocol-error accounting |
| [GH719](https://github.com/majiayu000/vibeguard/issues/719) | Ownership-safe per-skill opt-out for managed Codex copies |
| [GH720](https://github.com/majiayu000/vibeguard/issues/720) | Retired automatic SpecRail packet validation |

## Recovering an Archived Packet

Use the issue link above for discussion and merged PRs. When the removed packet
itself is needed, locate its deletion commit and read the parent tree:

```bash
git log --diff-filter=D -- docs/specs/GH703
git show <deletion-commit>^:docs/specs/GH703/tech.md
```

Do not restore a closed packet to `main`. Extract a historical file into an
ignored `artifacts/` directory when temporary local analysis needs it.

## Reading and Update Rules

- Current source and regression tests override archived design wording.
- A draft is design context only and never authorizes implementation.
- New issue-specific plans belong in the issue or an explicitly requested,
  bounded plan; they do not create a new `docs/specs/GH*` directory.
- When an outcome needs durable discovery, add or update one index row rather
  than restoring its packet.
- Execution plans under `plan/` have their own status index in `plan/README.md`.

## Validation

Run:

```bash
bash scripts/ci/validate-specs-index.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```
