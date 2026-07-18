# Adoption Matrix

Issue: [GH-13](https://github.com/majiayu000/specrail/issues/13)

This matrix records real repositories that have exercised part of the
SpecRail workflow. It is intentionally evidence-based: a repository is listed
only when the repo, issue, PR, spec packet, example, or test fixture can be
named from this repository.

## Adoption Levels

| Level | Meaning | Evidence threshold |
| --- | --- | --- |
| `referenced` | A repository informed a design or review pattern. | At least one issue, PR, local path, or test fixture is named. |
| `smoke` | SpecRail can inspect a read-only adoption scenario for the repository. | A smoke document or fixture exists and does not require writing to the target repo. |
| `spec_packet` | A real issue/spec/PR flow used SpecRail-style artifacts. | Product and tech spec paths, linked issue, and PR evidence are recorded. |
| `pr_gate` | The repository exercised PR evidence or merge-readiness checks. | PR evidence, review-thread, CI, or gate fixture is recorded. |
| `repo_integrated` | The target repository carries SpecRail workflow files or an equivalent overlay. | Target repo has adopted workflow config, agent instructions, or copied pack assets. |
| `automation_ready` | Repeated manual runs are stable enough for comment-only or dry-run automation. | Multiple successful runs and maintainer approval are recorded. |

Levels are not a maturity promise. They describe the strongest verified signal
currently recorded in this repository.

## Current Matrix

| Repository | Current level | Status | Evidence | Next gap |
| --- | --- | --- | --- | --- |
| `rclean` | `smoke` | `needs_human` | `examples/rclean-smoke.md`, target-local `tests/test_specrail_adoption.sh`, and the upstream GH5 packet recorded as external evidence | Promote from read-only smoke to an explicit target-repo integration plan before writing into `rclean`. |
| `litellm-rs` | `pr_gate` | `active` | target-local `checks/pr_gate.py`, `examples/fixtures/pr-clean-authorized.json`, `tests/test_specrail_adoption.sh`, the upstream GH7 packet recorded as external evidence, and PR `majiayu000/litellm-rs#718` | Add reusable PR evidence fixtures for more review-thread and CI states. |
| `Claude-Code-Monitor` / `claude-hub` | `spec_packet` | `active` | External GH44 product and tech packets, issue `majiayu000/claude-hub#44`, PR `majiayu000/claude-hub#45` | Decide whether the target repo should carry a copied SpecRail pack or stay as an external pilot. |

The machine-readable record is `examples/adoptions/matrix.json`. VibeGuard's
adoption smoke checks that every target-local `specrail_artifact` path exists;
upstream or third-party pointers are marked as external evidence and are not
dereferenced by the offline check.

## Gate Fixture Corpus

`examples/fixtures/` contains deterministic inputs for route, PR, and review
gate tests. These fixtures are benchmark artifacts for SpecRail's local policy
checks. They are not live GitHub state and do not claim that a repository has
adopted SpecRail.

## Non-Goals

- This matrix does not claim that every listed repository is fully integrated.
- This matrix does not authorize automatic issue creation, labels, merge, or
  release actions.
- External artifact paths and local path hints are evidence pointers only. They
  must not be modified by matrix validation.
