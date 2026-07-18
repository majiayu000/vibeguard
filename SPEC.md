# SpecRail v0.1 Specification

## Problem

AI-assisted coding makes implementation cheaper, but repository workflow often
stays implicit. Without a shared state machine, agents and humans disagree about
whether a request needs clarification, a product spec, implementation, review,
or release notes.

SpecRail standardizes the repository workflow contract before automation.

## Scope

This pack defines:

- issue readiness states
- feature spec packets
- pull request review gates
- agent-first review boundaries
- human-final review boundaries
- deterministic workflow checks

## Non-Goals

- Building a hosted Oz-style control plane.
- Replacing GitHub issues or pull requests.
- Granting final approval or merge authority without explicit current user
  authorization and all required offline evidence.
- Handling private security reports through public issues.
- Enforcing language-specific build rules.

## Workflow Model

```text
new_issue
  -> needs_info | duplicate | security_private | triaged

triaged
  -> ready_to_spec | ready_to_implement | reserved_internal

ready_to_spec
  -> spec_pr_open
  -> spec_review
  -> spec_approved
  -> ready_to_implement

ready_to_implement
  -> impl_pr_open
  -> agent_review
  -> human_review
  -> ci_green
  -> merge_ready
  -> merged
  -> release_note_drafted
```

## Agent Boundary

Agents may:

- propose labels
- draft product and tech specs
- draft implementation plans
- perform first-pass PR review
- diagnose CI failures
- draft release notes

Agents must not:

- approve pull requests as final authority
- merge unless either the current invocation explicitly selected auto mode or
  the current conversation contains per-PR review-mode authorization, and
  current CI, `pr_gate`, review-thread, reviewer-lane, and merge-state evidence
  all pass
- close disputed issues
- publish secrets or security findings
- change repository permissions
- bypass maintainer readiness labels

## Required Artifacts

Feature work that is not clearly small and actionable requires a spec packet:

```text
docs/specs/GH<issue-number>/
  product.md
  tech.md
```

Bug fixes may skip the spec packet only when the issue has reproduction steps,
expected behavior, actual behavior, and an accepted `ready_to_implement` label.

## Verification

The first validator is intentionally deterministic:

- required files exist
- workflow labels are declared
- templates include required sections
- JSON schemas parse
- optional spec packets contain `product.md` and `tech.md`
- optional GitHub PR merge evidence can be collected read-only with
  `checks/github_pr_evidence.py`
- optional PR merge evidence can be checked with `checks/pr_gate.py`
- optional GitHub issue evidence can be collected read-only with
  `checks/github_issue_evidence.py`
- optional advisory review artifacts can be checked against a diff with
  `checks/review_json_gate.py`
- repo-distributed skills can be pinned with `skills-lock.json`

LLM-based triage and review should be added only after the deterministic checks
are stable.

## Runtime Checkpoint Contract Authority

For `.specrail/runtime/current.json`, `checks/runtime_ledger_gate.py` is the
behavior authority and `schemas/runtime_checkpoint.schema.json` is the structure
authority. The schema covers JSON shape, required fields, enum values, and
nested object structure. The gate covers semantic rules that JSON Schema cannot
express cleanly here, such as fresh head SHA evidence, merge authorization,
review-thread cleanliness, and queue-drain completion semantics.

Tests keep the two in sync by validating representative runtime checkpoint
instances against the schema and checking their gate decisions. The gate does
not read the schema at runtime, so it can still diagnose malformed or missing
schema files independently.
