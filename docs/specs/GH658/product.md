# Product Spec — required work_surface routing classifier

## Linked Issue

GH-658

complexity: medium

## User Problem

The routing contract classifies only implementation readiness. Writing,
research, and direct chat-support requests therefore inherit code-execution
demands such as builds, changed-file lists, root-cause templates, and PR
readiness even when the requested deliverable is not code.

## Goals

- Classify the requested deliverable surface before applying risk and
  readiness routing.
- Keep code-only execution requirements off writing, research, and direct
  chat-support work unless the user requests repository edits.
- Make missing or invalid work-surface metadata fail schema validation.

## Non-Goals

- No change to the three readiness outputs or their meanings.
- No change to shared planning-handoff keys.
- No compatibility fallback for routing-decision producers that omit the new
  required field.
- No unrelated writing-style policy.

## Behavior Invariants

1. B-001: A routing-decision payload without `work_surface` fails schema
   validation.
2. B-002: `work_surface.decision` accepts exactly `code_execution`,
   `writing_research`, or `chat_support`; `work_surface.reason` is required
   and nonempty.
3. B-003: `precedence` is required and must equal this exact six-stage array:
   `user_override`, `work_surface_classifier`, `risk_destructive_gate`,
   `ambiguity_gate`, `readiness_classifier`, and
   `execution_or_delegation_lane`. Missing, reordered, duplicated, or extra
   stages fail schema validation.
4. B-004: The dispatcher requires upstream `work_surface` and does not
   convert `writing_research` or `chat_support` into `code_execution` unless
   the upstream decision or a new user instruction requests repository edits.
5. B-005: Delivery workflows start only for `code_execution`; other surfaces
   do not enter build/edit flows merely because readiness is otherwise clear.
6. B-006: `writing_research` keeps domain-appropriate verification such as
   source citation, fact/interpretation separation, and saved-artifact
   inspection without forcing code-only evidence.
7. B-007: Every shipped instruction surface that summarizes routing tells the
   agent to classify `work_surface` before choosing readiness.
8. B-008: Contract tests prove a valid payload passes and that missing
   `work_surface`, an unknown decision, and an empty reason each fail loudly.
9. B-009: `chat_support` produces the requested direct conversational answer
   without build/test/changed-files/PR-readiness framing unless repository
   edits become part of the request.
10. B-010: Planning workflows preserve the validated `routing_decision`
    alongside the unchanged six-field execution handoff. Downstream consumers
    require both objects and fail loudly instead of inferring a missing
    `work_surface`.
11. B-011: Classification uses this deterministic priority: any repository,
    runtime, deployment, or executable-state mutation is `code_execution`; a
    durable prose/research artifact without project-state mutation is
    `writing_research`; a response with neither mutation nor durable artifact
    is `chat_support`. Mixed requests containing project-state mutation are
    `code_execution` while retaining writing-domain verification for their
    prose portion. Missing or conflicting facts route to clarification rather
    than a default.

## Acceptance Criteria

- [ ] A valid routing payload containing `work_surface` and `readiness`
      validates.
- [ ] Missing `work_surface`, an unknown surface, and an empty reason each
      produce a nonzero validation result with actionable error evidence.
- [ ] Missing, reordered, duplicated, or extra precedence stages each fail;
      only the exact required six-stage array validates.
- [ ] All three valid work-surface values pass with nonempty reasons.
- [ ] Dispatcher, delivery, workflow, and instruction surfaces preserve the
      behavior mapped by B-004 through B-011.
- [ ] Plan-mode and plan-flow persist the routing decision beside the
      six-field handoff, and consumers reject either object when incomplete.
- [ ] Workflow contract and manifest contract suites pass fresh.

## Boundary Checklist

| Category | Verdict (covered: B-xxx / N/A + reason) |
| --- | --- |
| Empty / missing input | covered: B-001, B-002 |
| Error / failure paths | covered: B-001, B-002, B-008 |
| Authorization / permission | N/A — classification does not grant authority or bypass action gates |
| Concurrency / race | N/A — one routing decision is classified independently |
| Retry / idempotency | N/A — classification is stateless and repeatable |
| Illegal state transitions | covered: B-004, B-005, B-010, B-011 |
| Compatibility / migration | covered: B-001, B-008 — this is intentionally breaking and fail-closed |
| Degradation / fallback | covered: B-006, B-009, B-010, B-011 — verification is translated and missing classification fails loudly |
| Evidence / audit integrity | covered: B-002, B-003, B-008, B-010 |
| Cancellation / interruption | N/A — no execution or cancellation semantics change |

## Rollout Notes

Every routing-decision producer must add a `work_surface` object before
adopting the updated schema. There is no default or compatibility fallback.
