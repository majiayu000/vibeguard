# Agent Usage

SpecRail is primarily for code agents, not for human project management. Humans
own policy and final gates; agents use this repository to decide how to triage,
write specs, prepare PRs, review, and report handoffs without inventing process.

## VibeGuard Adoption Pin

VibeGuard adopted this pack from `majiayu000/specrail` commit
`7de16e4780d903607b40220a9edb7a08fe222c78` on 2026-07-14. Consumer-specific
overrides keep spec packets under `docs/specs/GH<number>`, set the default
locale to `zh-CN`, align imported skills with VibeGuard's required skill
sections, and replace source-only example paths with target-local evidence.
VibeGuard's own README, LICENSE, and CHANGELOG remain authoritative.

## What The Agent Should Load

When a repository adopts SpecRail, the agent should read these files before
creating issues, specs, PRs, or reviews:

1. `AGENTS.md`
2. `workflow.yaml`
3. `states.yaml`
4. `labels.yaml`
5. the relevant template under `templates/` or `templates/<locale>/`
6. `skills/specrail-workflow/SKILL.md` when available
7. `skills-lock.json` when the repository carries repo-distributed skills

If the consumer repository has no `AGENTS.md`, ask the maintainer to add a short
entrypoint or proceed from `AGENT_USAGE.md` only for the current task while
reporting that the repo is missing its agent entrypoint. Do not treat a missing
`AGENTS.md` as permission to skip `workflow.yaml`, `states.yaml`, `labels.yaml`,
or the relevant templates.

The skill is an execution guide. The YAML files and templates are the workflow
contract. The agent should not treat the skill as final authority when it
conflicts with repository policy or human instructions.

Optional integration documents under `integrations/` are loaded only when the
task needs that execution model. They do not replace the core SpecRail contract.

For setup, installation, update, verification, or adoption requests, load
`skills/specrail-install/SKILL.md` first. Treat it as the agent-facing setup
entrypoint; command-line installers are deterministic helpers, not the primary
interface a human must memorize.

## Autonomous SpecRail Mode

Agents should switch complex work into SpecRail mode even when a repository has
not adopted the full pack. Good triggers include product-facing changes,
architecture changes, cross-module work, public API changes, workflow-policy
changes, PR merge-readiness checks, CI diagnosis with unclear ownership, or
ambiguous requests whose done-when is not yet testable.

SpecRail mode means the work is actually structured as a SpecRail flow: search
first, select the route, produce or request durable product/tech/task artifacts
before broad implementation, preserve human gates, and run deterministic
verification. Do not treat SpecRail as a loose checklist or a note in the final
answer.

If a repository has not adopted the pack, use that repository's existing
specs/plan/docs location to carry the route, spec, task plan, and verification
evidence. Do not silently copy the SpecRail pack into a repository, install
local skills, create remote issues or PRs, add labels, approve, merge, or bypass
maintainers unless the user explicitly asks for that action.

For small mechanical fixes, test-only changes, doc-only corrections, or
approved-spec work, direct implementation is still appropriate.

## Optional Local Skill Installation

Repository adoption does not require installing SpecRail skills into `$HOME`.
Agents must not run a local skill install with `--apply` unless a human
explicitly requests local Codex skill installation.

When local installation is explicitly requested, preview first:

```sh
python3 tools/install_codex_skills.py --repo .
```

Apply only after that explicit request:

```sh
python3 tools/install_codex_skills.py --repo . --apply
```

The installer validates `skills-lock.json`, writes only the locked skill
directories, and targets `$CODEX_HOME/skills` or `~/.codex/skills`. A running
agent session may need to restart before the installed skills are discoverable.

## Basic Agent Flow

1. Search existing issues and PRs before creating new work.
2. Identify the route:
   - `triage_issue`
   - `write_spec`
   - `implement`
   - `review_pr`
   - `fix_ci`
   - `draft_release_note`
3. Default to `write_spec` before `implement` for product-facing,
   architecture, cross-module, public API, workflow-policy, or ambiguous
   behavior changes.
4. Choose direct `implement` only when an approved spec already exists, the
   change is small and mechanical, or the user explicitly asks to skip spec
   creation.
5. Confirm the current state from durable repo state when possible.
6. Create or update the required artifact. For spec artifacts, use the
   configured `artifacts.product_spec`, `artifacts.tech_spec`, and
   `artifacts.task_plan` paths from `workflow.yaml`:
   - issue
   - configured product, tech, and task spec paths
   - PR body
   - review result
   - handoff
7. Run the local evaluator before taking the route action:

```sh
python3 checks/github_issue_evidence.py --repo . --github-repo OWNER/REPO --issue <issue-number> --json > issue-evidence.json
python3 checks/github_duplicate_evidence.py --github-repo OWNER/REPO --issue <issue-number> --json > duplicate-work-evidence.json
python3 checks/route_gate.py --repo . --route write_spec --issue <issue-number> --evidence issue-evidence.json --json
python3 checks/route_gate.py --repo . --route write_spec --issue <issue-number> --state ready_to_spec --json
python3 checks/route_gate.py --repo . --route implement --issue <issue-number> --state ready_to_implement --duplicate-evidence duplicate-work-evidence.json --json
```

The duplicate-work adapter is read-only. It collects open PR and remote branch
evidence; `checks/duplicate_work_gate.py` and `route_gate.py` evaluate that
evidence offline so duplicate implementation work is blocked before a new PR is
opened.

8. Run deterministic checks before claiming completion:

```sh
python3 checks/check_workflow.py --repo .
python3 checks/check_workflow.py --repo . --all-specs
```

`--all-specs` discovers packets from `workflow.yaml`'s
`artifacts.spec_packet` template. The issue evidence adapter and route gate
render their spec paths from the same artifact configuration. For a single
packet, run the exact configured command returned by `route_gate.py` in
`verification_commands`.

9. Before reporting a PR as merge-ready, collect PR evidence and run:

```sh
python3 checks/github_pr_evidence.py \
  --github-repo OWNER/REPO \
  --pr <pr-number> \
  --review-source independent_lane \
  --json > pr-evidence.json
python3 checks/pr_gate.py --repo . --evidence <evidence.json> --json
```

For a partial implementation slice whose body contains a standalone
`Refs #<issue-number>` directive, bind the intended issue explicitly:

```sh
python3 checks/github_pr_evidence.py \
  --github-repo OWNER/REPO \
  --pr <pr-number> \
  --issue <issue-number> \
  --review-source independent_lane \
  --json > pr-evidence.json
```

The adapter verifies that target against the live same-repository issue and
requires it to remain open. Other bounded closing references may coexist and
are retained in `issue_reference.closing_issue_numbers`; they do not redirect
the explicitly selected `linked_issue`. A verified `partial` relation satisfies
only the PR gate's linked-work requirement. It does not prove final-slice
completion and does not authorize issue closure.

The GitHub adapter is read-only and only reshapes `gh` output. The PR gate is
offline. GitHub or `threads` may collect evidence such as PR head SHA, CI
status, review threads, review source, lane failures, merge state, and linked
issue references. Resolver role mapping comes from explicit lane-roster evidence
such as `--resolver-role-map`; the adapter must not infer it from GitHub alone.
The gate only evaluates that evidence and never merges or writes remote state.
Self-review evidence must use `--review-source self_review` plus
self-review authorization fields recorded after the lane failure.

For long agent runs, maintain an optional local runtime checkpoint before
handoff or compaction:

```sh
python3 checks/runtime_ledger_gate.py --checkpoint .specrail/runtime/current.json --json
```

Use the checkpoint to preserve tranche scope, context budget, output-firewall
settings, verification evidence paths, blockers, and resume prompts. Do not use
it as a replacement for GitHub issues, PRs, labels, reviews, branches, or
SpecRail spec packets.

Issue evidence includes `state_source` and `state_trusted`. Label-derived state
is trusted readiness evidence. Body-hint state is useful context, but it is not
a maintainer readiness label and human-gated routes must not treat it as direct
permission.

10. Before treating an agent review artifact as publishable evidence, validate
    it against the diff:

```sh
python3 checks/review_json_gate.py --repo . --review artifacts/review/pr-<pr-number>.json --diff <patch> --json
```

The review gate validates advisory review JSON and inline diff locations. It
does not approve, merge, or publish GitHub reviews. Review artifact bodies must
include `## Summary` and `## Verdict`; inline comments may use paired
`start_line` / `start_side` ranges, and suggestions must be non-empty RIGHT-side
comments.

If `write_spec` is selected and no GitHub issue number is available, the agent
should search for an existing issue first. If none exists and GitHub workflow is
in scope, create or request a linked issue before writing the numbered spec
packet. A missing issue number is not permission to skip spec creation.

## Optional Threads Integration

If the task is a GitHub issue or PR queue, needs disjoint parallel lanes, or
requires review-thread, CI, merge-gate, or closure-audit handling, load
`skills/specrail-implement-queue/SKILL.md` after SpecRail preflight. SpecRail still owns policy,
locale, required artifacts, and human gates. Threads owns lane orchestration,
remote queue truth, and closure audit.

For GitHub PR review or merge work, native reviewer or merge-reviewer dispatch
is required when native subagent capability is available. Record
`thread_dispatch_gate` and native thread evidence before claiming full threads
execution or merge readiness.

For long queues, keep the parent thread thin: write raw logs to artifacts, read
only short summaries or tails, and checkpoint before continuing in a fresh
parent thread.

If no threads skill or native subagent capability is available, continue with
the normal single-agent SpecRail flow only after recording the fallback and
reporting that no native threads were launched.

## Locale Behavior

Use human-facing text in the selected locale. If the user writes Chinese or the
selected locale is `zh-CN`, write these in Chinese:

- issue bodies
- product specs
- tech specs
- PR bodies
- review summaries
- handoffs
- error explanations

Do not translate stable machine-facing identifiers:

- action IDs such as `write_spec`
- state IDs such as `ready_to_spec`
- decision values such as `needs_human`
- artifact IDs such as `product_spec`
- paths such as `docs/specs/GH539/product.md`
- commands and CLI flags
- JSON keys and schema field names

Use this locale selection order:

1. explicit user request
2. user's current language
3. `presentation.default_locale` in `workflow.yaml`
4. `presentation.fallback_locale`

## What Exists Today

SpecRail currently provides:

- state and label conventions
- issue/spec/PR templates
- `zh-CN` templates
- localized message files
- an optional threads integration design
- a Codex-compatible `specrail-workflow` router skill and focused route skills
- a Codex-compatible `specrail-install` setup skill for agent-facing installs
- `skills-lock.json` for repo-distributed SpecRail skills
- a deterministic pack validator
- a read-only GitHub issue evidence adapter
- a read-only GitHub PR evidence adapter
- a read-only duplicate-work evidence adapter and offline implementation
  duplicate-work gate
- an advisory review JSON gate
- an optional runtime checkpoint gate for long agent-run handoffs
- a local evaluator that returns `allowed`, `warn`, `needs_human`, or `blocked`
- an adoption matrix and fixture for real repo pilot evidence:
  `docs/ADOPTION_MATRIX.md` and `examples/adoptions/matrix.json`
- gate benchmark fixtures under `examples/fixtures/`

This is enough for an agent to follow the process more consistently than raw
README instructions.

## What Does Not Exist Yet

SpecRail does not yet provide:

- automatic issue label checks
- automatic template rendering commands
- automatic merge or final approval

Until those exist, agents should treat `checks/route_gate.py` as a local gate and
must report what they verified rather than claiming live GitHub workflow state
from assumptions.

## Human Gates

Agents may draft, propose, review, and diagnose. Agents must not:

- provide final approval
- merge without explicit authorization
- publish private security details
- change repository permissions
- bypass readiness labels or other human gates
