# Agent Usage

VibeGuard repository work starts from the current request, live repository
state, and the routing contract in `AGENTS.md`. SpecRail is optional tooling in
this repository. Use it only when explicitly requested; it does not authorize
implementation, approval, merge, release, or any other remote write.

## Default Repository Flow

1. Check `git status --short --branch` and confirm the repository root.
2. Search existing issues, pull requests, branches, specs, plans, and code
   before creating new work.
3. Classify the work surface and readiness with
   `workflows/references/routing-contract.md`.
4. For writable GitHub work, refresh live remote state and use an isolated
   worktree based on the current remote base.
5. Implement only the requested scope and run fresh verification for the
   changed surface.
6. Before reporting merge readiness, verify the current PR head SHA, required
   CI, independent review, unresolved review threads, merge state, and linked
   issue scope.
7. Merge, release, permission changes, force pushes, and publication of private
   security details require explicit human authorization.

Repository-local plans and specs remain useful context. Read
`docs/specs/README.md` and `plan/README.md` before treating a file as active
work; implemented and historical records are not a live backlog.

## GitHub Queue Work

Use live GitHub state rather than labels or local branches remembered from an
earlier run. Map every open issue to existing PR coverage before creating a new
branch. Prefer updating a safe existing covering PR over opening competing
work.

Keep these facts separate:

- remote issue and PR state
- current PR head SHA and CI rollup
- unresolved and outdated review-thread state
- mergeability and base-branch freshness
- local branch, worktree, dirty-file, and unpushed-commit state

Use native `threads` when the user explicitly requests threads or when the
selected queue workflow requires independent lanes. Writable lanes need
disjoint ownership. Reviewers remain read-only, and a worker's self-review does
not replace independent review when that is required.

## Optional SpecRail Tooling

The adopted SpecRail pack and its evidence adapters are retained for explicit
optional use. They are not automatically invoked by PR or push workflows, do
not auto-activate for complex work, and are not prerequisites for ordinary
issue, implementation, review, or merge-readiness work.

When the user explicitly requests SpecRail, load the relevant optional assets:

1. `workflow.yaml`
2. `states.yaml`
3. `labels.yaml`
4. the relevant file under `templates/` or `templates/<locale>/`
5. `skills/specrail-workflow/SKILL.md`
6. `skills-lock.json`

The local evaluators, YAML files, schemas, templates, skills, and
`docs/specs/GH<number>/` packets are optional offline tools. Their state labels
and evaluator decisions are advisory local evidence; they do not replace the
repository's generic routing decision or live GitHub and CI evidence.

### VibeGuard Adoption Pin

VibeGuard adopted the offline pack from `majiayu000/specrail` commit
`7de16e4780d903607b40220a9edb7a08fe222c78` on 2026-07-14. Consumer-specific
overrides keep spec packets under `docs/specs/GH<number>`, set the default
locale to `zh-CN`, align imported skills with VibeGuard's required skill
sections, and replace source-only example paths with target-local evidence.
VibeGuard's own README, LICENSE, CHANGELOG, root instructions, and ordinary CI
remain authoritative.

### Local Skill Installation

Repository contents do not authorize writing SpecRail skills into `$HOME`.
Only when local installation is explicitly requested, preview first:

```sh
python3 tools/install_codex_skills.py --repo .
```

Apply only after that explicit request:

```sh
python3 tools/install_codex_skills.py --repo . --apply
```

The installer validates `skills-lock.json`, writes only locked skill
directories, and targets `$CODEX_HOME/skills` or `~/.codex/skills`.

### Offline Validation

The optional pack validator can check the retained configs, assets, and spec
packets:

```sh
python3 checks/check_workflow.py --repo .
python3 checks/check_workflow.py --repo . --all-specs --spec-stage complete
python3 checks/check_workflow.py \
  --repo . \
  --spec-dir docs/specs/GH<issue-number> \
  --spec-stage draft
```

Draft mode validates `tasks.md` when present. With an explicit `--base-ref`, it
also detects removal of a baseline task plan. These are offline integrity
checks for an explicitly selected SpecRail flow, not automatic repository
gates.

### Read-Only Live GitHub Evidence

The optional `github_issue_evidence.py`, `github_duplicate_evidence.py`, and
`github_pr_evidence.py` adapters invoke `gh`. They require network access and an
authenticated `gh` session. They collect and normalize live evidence without
writing GitHub state:

```sh
python3 checks/github_issue_evidence.py \
  --repo . \
  --github-repo OWNER/REPO \
  --issue <issue-number> \
  --json

python3 checks/github_duplicate_evidence.py \
  --github-repo OWNER/REPO \
  --issue <issue-number> \
  --json

python3 checks/github_pr_evidence.py \
  --github-repo OWNER/REPO \
  --pr <pr-number> \
  --review-source independent_lane \
  --json
```

Neither successful collection nor its output authorizes a remote mutation.
These adapters do not auto-activate.

### Offline Evaluators

The optional local evaluators consume repository files or previously collected
evidence without contacting GitHub:

```sh
python3 checks/route_gate.py \
  --repo . \
  --route implement \
  --issue <issue-number> \
  --state ready_to_implement \
  --json

python3 checks/pr_gate.py \
  --repo . \
  --evidence <evidence.json> \
  --json
```

Evaluator results such as `allowed`, `warn`, `needs_human`, or `blocked`
describe only the supplied offline evidence. The evaluators do not
auto-activate, authorize a remote action, or replace required live evidence.

For an explicitly selected long SpecRail run, an optional local checkpoint can
preserve handoff evidence:

```sh
python3 checks/runtime_ledger_gate.py \
  --checkpoint .specrail/runtime/current.json \
  --json
```

The checkpoint does not replace issues, PRs, reviews, branches, CI, or native
thread state.

An explicitly requested advisory review artifact can be validated against a
diff:

```sh
python3 checks/review_json_gate.py \
  --repo . \
  --review artifacts/review/pr-<pr-number>.json \
  --diff <patch> \
  --json
```

This validation does not publish, approve, or merge a GitHub review.

## Locale Behavior

Use human-facing text in the user's requested language. If no language is
specified, follow the user's current language. For an explicitly selected
SpecRail flow, `presentation.default_locale` in `workflow.yaml` is the next
fallback.

Do not translate stable machine-facing identifiers, paths, commands, CLI flags,
JSON keys, schema fields, state IDs, or action IDs.

## Preserved Human Boundaries

Agents may inspect, draft, implement within assigned scope, review, and
diagnose. They must not:

- provide final human approval
- merge or release without explicit authorization
- publish private security details
- change repository permissions without explicit authorization
- bypass required ordinary CI or unresolved review-thread evidence
- treat optional SpecRail output as permission for a remote write
