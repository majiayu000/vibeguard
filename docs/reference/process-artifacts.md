# Process Artifact Policy

VibeGuard keeps source, deterministic product fixtures, and maintained
documentation in Git. Session output and tool receipts are local evidence, not
repository source.

## Never Commit

Put disposable process output under the ignored `artifacts/` directory. This
includes:

- agent routing packets, handoff receipts, review transcripts, and scorecards;
- triage exports, issue snapshots, runtime snapshots, and tool inventories;
- logs, screenshots, benchmark output, generated reports, and temporary diffs;
- files whose only purpose is to prove that a local command ran.

Do not force-add ignored output. A PR description or CI link is the durable
record for validation results. Closed `docs/specs/GH*` packets are archived by
Git history and summarized in `docs/specs/README.md`; they must not be restored
to the current tree.

## What May Be Committed

A generated or evidence-like file may be tracked only when it is part of the
product or a stable repository contract:

1. deterministic generated documentation with a canonical source and a
   freshness check;
2. minimal test fixtures required by a regression test;
3. versioned schemas, manifests, seed data, or release metadata consumed by
   shipped code or CI;
4. an explicitly requested architecture plan or active design document that
   follows the repository's delivery limits.

Store an allowed file beside its owning source, test, or schema—not under
`artifacts/`. Remove temporary snapshots when their owning work closes unless
current product behavior or a regression test still consumes them.

## Decision Test

Before adding an output-like file, answer all three questions:

1. What current source, test, shipped behavior, or maintainer decision consumes
   this file?
2. Why is a PR description, issue comment, CI run, or Git history insufficient?
3. What focused check will fail if this file becomes stale or disappears?

If any answer is missing, keep the file local under `artifacts/`.
