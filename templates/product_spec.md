# Product Spec

## Linked Issue

GH-

## User Problem

Describe the user-visible problem and why it matters.

## Goals

-

## Non-Goals

-

## Behavior Invariants

List numbered, testable behavior requirements without implementation details.
Use stable IDs (`B-001`, `B-002`, ...); revisions append, never renumber or
reuse. Prefer EARS-style conditional triggers (WHEN / IF / WHILE / 当 / 如果 /
若) so each invariant names the condition under which it fires. Follow the
length heuristic, density rule, and worked example in the
`specrail-write-product-spec` skill. For trivial changes declare
`complexity: trivial` under Linked Issue and keep the spec minimal.

1. B-001

## Acceptance Criteria

- [ ]
- [ ]

## Boundary Checklist

Every category is either covered by a named invariant or N/A with a reason.
Watch for combinations (e.g. authorized + prerequisite evidence absent).

| Category | Verdict (covered: B-xxx / N/A + reason) |
| --- | --- |
| Empty / missing input |  |
| Error / failure paths |  |
| Authorization / permission |  |
| Concurrency / race |  |
| Retry / idempotency |  |
| Illegal state transitions |  |
| Compatibility / migration |  |
| Degradation / fallback |  |
| Evidence / audit integrity |  |
| Cancellation / interruption |  |

## Rollout Notes

Describe migration, compatibility, or communication needs.
