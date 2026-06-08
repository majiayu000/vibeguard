---
name: benchmark-regression-triage
description: Use this skill whenever VibeGuard hook latency, benchmark-action output, GitHub Actions bench-output artifacts, or a suspected performance regression needs investigation. It preserves the PR-to-CI-artifact workflow for comparing recent PRs, older anchors such as PR #350, and current main without mixing local machine noise into CI trend evidence.
---

# Benchmark Regression Triage

## Overview

This skill diagnoses VibeGuard hook latency regressions by comparing GitHub Actions `bench-output` artifacts across PR runs, merge runs, and mainline runs. It is meant for non-obvious cases where the current benchmark is under budget but slower than a previous design, such as a `post-write-guard` path losing its `post-write-fast-check` fast path after a runtime migration.

Treat CI artifacts as the trend source. Local benchmarks are useful for reproduction after a hypothesis exists, but they are not comparable to GitHub runner history because machine load, shell startup, cache state, and `--runs` count can dominate P95.

## When to Activate

- A user asks why VibeGuard benchmark numbers are slower than before.
- A PR appears to change hook latency, benchmark output, or benchmark-action reporting.
- You need to compare recent PRs with older anchors such as PR #350 or a known fast-path implementation.
- A hook is still below the absolute latency budget but may have lost a faster design.
- You need a reusable workflow for downloading and comparing GitHub Actions `bench-output` artifacts.

## Inputs

Collect these before drawing conclusions:

- Repository full name from `gh repo view`.
- Candidate PR numbers or commits, including one recent run and one older anchor.
- GitHub Actions run IDs tied to the exact PR head, merge commit, or main commit.
- `bench-output.json` from each run, downloaded into separate directories.
- The relevant budget contract from `docs/reference/hook-latency-contract.md`.

## Workflow

### 1. Search Existing Context

Search before adding a new hypothesis or artifact path:

```bash
rg -n "benchmark|bench-output|hook latency|post-write-fast|post-write-fast-check|post-write-guard|github-action-benchmark" \
  .github docs tests hooks scripts skills workflows README.md CHANGELOG.md
```

Open the latency contract and CI workflow:

```bash
sed -n '1,120p' docs/reference/hook-latency-contract.md
sed -n '270,420p' .github/workflows/ci.yml
```

Confirm whether the benchmark artifact is uploaded from Linux only. In this repo, the `Upload benchmark results` step is guarded by `runner.os == 'Linux'`, so artifact comparisons should use the Linux `bench-output` artifact unless the workflow changes.

### 2. Identify PR and Mainline Runs

Start with metadata, not assumptions:

```bash
REPO="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')"

gh pr view 417 --repo "$REPO" \
  --json number,title,state,mergedAt,headRefName,baseRefName,mergeCommit,url

gh pr view 350 --repo "$REPO" \
  --json number,title,state,mergedAt,headRefName,baseRefName,mergeCommit,url

gh run list --repo "$REPO" --branch main --limit 30 \
  --json databaseId,workflowName,event,displayTitle,headSha,createdAt,status,conclusion,url
```

For a PR head branch, resolve the branch and list its runs:

```bash
PR=417
HEAD_BRANCH="$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq '.headRefName')"

gh run list --repo "$REPO" --branch "$HEAD_BRANCH" --limit 20 \
  --json databaseId,workflowName,event,displayTitle,headSha,createdAt,status,conclusion,url
```

Record whether each run is a `pull_request` run, a merge-to-main run, or a later mainline run. Do not compare an unrelated later main commit against a PR head without stating the extra changes in between.

### 3. Download Benchmark Artifacts

For each chosen run, confirm the artifact exists:

```bash
RUN_ID=27085248846

gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts" \
  --jq '.artifacts[] | select(.name == "bench-output") | [.id, .name, .expired, .size_in_bytes] | @tsv'
```

Download into a per-run directory so files do not overwrite each other:

```bash
LABEL="pr-417-head"
OUT="/tmp/vg-bench/$LABEL"
rm -rf "$OUT"
mkdir -p "$OUT"

gh run download "$RUN_ID" --repo "$REPO" -n bench-output -D "$OUT"
test -f "$OUT/bench-output.json"
```

If an old PR artifact has expired, do not present reconstructed local numbers as historical CI truth. Use the old run logs or benchmark-action report if available, otherwise label the old comparison as a code-path reconstruction and state the evidence gap.

### 4. Extract Comparable P95 Values

Extract only P95 rows when checking the latency contract:

```bash
jq -r '
  .[]
  | select(.name | endswith("(P95)"))
  | [.name, .value]
  | @tsv
' "$OUT/bench-output.json"
```

For side-by-side comparisons, keep run IDs and labels visible:

```bash
for file in /tmp/vg-bench/*/bench-output.json; do
  label="$(basename "$(dirname "$file")")"
  jq -r --arg label "$label" '
    .[]
    | select(.name | endswith("(P95)"))
    | [$label, .name, .value]
    | @tsv
  ' "$file"
done
```

Normalize fixture names exactly. Compare `post-write-guard (100) (P95)` to the same fixture in another run, not to `post-write-guard (5000)` or a P50/P99 row.

### 5. Compare Against Budgets and Prior Design

Use the contract to decide whether CI is failing:

```bash
bash tests/bench_hook_latency.sh --runs=3 --fail-on-regression
```

Use artifact deltas to decide whether a design got slower:

- Under budget means acceptable by the current CI gate.
- Slower than a known fast path can still be a real regression worth fixing.
- A one-run delta needs code evidence before claiming root cause.

For the `post-write-guard` fast-path incident, the useful comparison was:

- Recent PR and mainline artifacts showed `post-write-guard` P95 stayed under budget.
- Older code around PR #350 had a `post-write-fast-check` front path that allowed clean writes to exit before full duplicate and quality scans.
- Later runtime consolidation preserved correctness but the wrapper path no longer called the fast check first, so clean writes paid the full `post-write-check` cost.

### 6. Locate the Root Cause

Do not stop at a chart. Tie the numbers to a code path:

```bash
rg -n "post-write-fast-check|post-write-check|post-write-guard|FALLBACK|NEEDS_FULL_CHECK" hooks tests vibeguard-runtime scripts

git log --oneline --decorate -- hooks/post-write-guard.sh hooks/post-write-fast-check.sh tests/bench_hook_latency.sh

git show <old-commit>:hooks/post-write-guard.sh | sed -n '1,220p'
git show <new-commit>:hooks/post-write-guard.sh | sed -n '1,220p'
```

Classify the finding carefully:

- `budget failure`: the benchmark gate exceeds the contract.
- `design regression`: the benchmark is still green, but a previously cheap safe path became more expensive.
- `measurement gap`: old artifacts expired or the compared runs are not equivalent.

### 7. Verify a Fix or Recommendation

If code is changed, run the focused checks for the touched surface:

```bash
bash tests/test_hook_perf_contract.sh
bash tests/bench_hook_latency.sh --runs=3 --fail-on-regression
bash scripts/ci/validate-hook-perf.sh
git diff --check
```

When the change touches Rust runtime code, add:

```bash
cargo check --manifest-path vibeguard-runtime/Cargo.toml
cargo test --manifest-path vibeguard-runtime/Cargo.toml
```

When the work is only a skill or document, run skill format validation instead:

```bash
python3 scripts/skill_validate.py --format-only --proposed-skill path/to/SKILL.md
```

## Report Format

Use this compact report shape:

```text
facts:
- repo:
- runs compared:
- artifact paths:

comparison:
| fixture | old anchor | recent PR | merge/main | budget |
|---|---:|---:|---:|---:|

root_cause:
- classification:
- evidence:
- affected path:

pitfalls_checked:
- same fixture and metric:
- CI artifact vs local benchmark separated:
- run IDs tied to commits:

verification:
- commands:
- result:

gaps:
- expired artifacts or non-equivalent runs:
```

## Red Flags

- Comparing local benchmark output to CI artifact history as if they came from the same environment.
- Reporting a benchmark regression without the run ID, commit SHA, event type, and downloaded artifact path.
- Treating a green budget result as proof that no design regression happened.
- Comparing different fixtures, such as `post-write-guard (100)` against `post-write-guard (5000)`.
- Guessing root cause from timing alone without checking the hook wrapper, runtime path, or relevant git history.

## Checklist

- [ ] Search existing benchmark docs, CI workflow, tests, and hook paths before adding a new hypothesis.
- [ ] Download `bench-output` artifacts into separate per-run directories.
- [ ] Compare the same P95 fixture names across PR, merge, and mainline runs.
- [ ] Tie every run to a PR number, commit SHA, event type, and Actions URL.
- [ ] Separate CI trend evidence from local reproduction measurements.
- [ ] Check the code path and git history before naming root cause.
- [ ] Run focused verification or clearly state why validation is unavailable.

## Boundaries

This skill does not change benchmark budgets by itself. Budget changes need separate justification in `docs/reference/hook-latency-contract.md`, CI updates, and focused tests.

This skill does not authorize editing hooks, runtime code, or GC scripts. Use it to investigate and report. Implementation requires a separate explicit task with file ownership and verification.
