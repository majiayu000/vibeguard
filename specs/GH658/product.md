# Product Spec — work_surface classifier in the routing contract

Linked Issue: #658
complexity: medium

## Goals

Requests whose deliverable is prose, research, or a direct answer currently
get forced through code-execution framing (build/test evidence, changed-files
lists, PR-readiness, root-cause templates). Add a `work_surface` classifier
that runs before the risk gate so every routing decision first states what
kind of deliverable is being produced, and non-code surfaces stop inheriting
code-only verification demands.

## Non-Goals

- No change to the three `readiness` outputs or their semantics.
- No change to the shared planning-handoff keys (`mode`, `artifacts`,
  `runtime_pinning_snapshot`, `verification_owner`, `stop_conditions`,
  `lane_map`).
- No new workflow; existing workflows only gain a start precondition.

## Behavior Invariants

- B-001: A `routing_decision` payload without a `work_surface` object fails
  schema validation (`work_surface` joins `readiness` in `required`).
- B-002: `work_surface.decision` accepts exactly `code_execution`,
  `writing_research`, `chat_support`, and requires a non-empty `reason`.
- B-003: The routing precedence ladder has six stages with
  `work_surface classifier` second, between `user_override` and the
  risk/destructive gate; schema `precedence` requires all six entries.
- B-004: The dispatcher requires upstream `work_surface` and never converts
  `writing_research` or `chat_support` into `code_execution` unless the
  upstream route or a new user instruction asks for repository edits.
- B-005: Delivery/execution workflows (fixflow, optflow, auto-optimize, and
  the shared delivery base) start only when upstream `work_surface` resolved
  to `code_execution`.
- B-006: `writing_research` keeps verification translated to the writing
  domain (cite sources, separate fact from interpretation, inspect the saved
  artifact) and must not force build/test/changed-files/PR-readiness/
  root-cause framing unless code, generated site content, or repository
  files are edited.
- B-007: Every instruction surface that states the routing contract
  (`AGENTS.md`, `templates/AGENTS.md`, `claude-md/vibeguard-rules.md`,
  `docs/CLAUDE.md.example`, `docs/command-schemas.md`,
  `.claude/commands/vibeguard/preflight.md`, `skills/vibeguard/SKILL.md`)
  tells the agent to classify `work_surface` before choosing `readiness`.
- B-008: The workflow contract test validates a payload that includes
  `work_surface` against the updated schema and passes.

## Boundary Checklist

| Category | Verdict |
| --- | --- |
| Empty / missing input | covered: B-001 (missing work_surface rejected), B-002 (empty reason rejected) |
| Error and failure paths | covered: B-001/B-002 (schema validation is the failure surface) |
| Authorization / permission | N/A — routing metadata, no privileged action |
| Concurrency / race / ordering | covered: B-003 (classifier position is fixed in the precedence ladder) |
| Retry / repetition / idempotency | N/A — classification is stateless per request |
| Illegal state transitions | covered: B-004 (surface downgrade/upgrade requires explicit new instruction) |
| Compatibility / migration | covered: B-001 is intentionally breaking — downstream producers emitting routing decisions without `work_surface` fail validation; migration note below |
| Degradation / fallback | covered: B-006 (writing surface keeps verification, does not silently drop it) |

## Migration Note (breaking change)

Any downstream producer of `routing_decision` payloads must add a
`work_surface` object (`decision` + `reason`) and the
`work_surface_classifier` precedence entry before upgrading to the new
schema. There is no compatibility fallback by design (schema is fail-closed).

## Acceptance

`bash tests/test_workflow_contracts.sh` passes with the updated payload, and
a grep over the instruction surfaces listed in B-007 shows the classify-first
wording present.

## Open Questions

- None. Style guidance ("avoid stock contrast framing") rides along in the
  same surfaces as B-006 wording; it is advisory, not schema-enforced.
