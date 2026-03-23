# Sprint Dependency Graph

## Analysis

### File touch map per issue

| Issue | Files touched |
|-------|--------------|
| #18 | `hooks/post-build-check.sh` |
| #19 | `hooks/log.sh` |
| #20 | `hooks/post-build-check.sh`, `hooks/post-edit-guard.sh`, `guards/*/check_*.sh` |
| #21 | `guards/*/check_*.sh` |
| #22 | `guards/*/check_*.sh`, `rules/` |
| #23 | `hooks/post-build-check.sh` |
| #25 | `.gitattributes`, shell scripts |
| #27 | `hooks/pre-edit-guard.sh` |
| #28 | `guards/*/check_*.sh` |
| #29 | `guards/*/check_*.sh` |
| #30 | `guards/*/check_*.sh` |
| #31 | `hooks/*.sh` (block-decision hooks) |

### Dependency rationale

- **#19 → #18**: `log.sh` session ID is currently global (`~/.vibeguard/.session_id`); #19 makes it project-scoped. The session filter in #18 must reference the correct (project-scoped) session ID.
- **#18, #19 → #23**: Circuit breaker builds on session-filtered consecutive-fail counters; correct session scoping must exist first.
- **#20 → #27**: New test-infra protection guard should use message format v2 from day one.
- **#20 → #29**: Suppression comments need to reference stable rule identifiers introduced by the v2 message format.
- **#20 → #31**: Transparent correction replaces block messages; the correction output should use the v2 format.
- **#21, #22 → #28**: Fixing known FPs requires ast-grep (more precise detection, #21) and a graduation lifecycle (#22) to safely demote/promote rules.
- **#22 → #30**: Baseline scanning records which issues are "existing"; the graduation system's rule metadata is a prerequisite for annotating baseline entries correctly.

SPRINT_PLAN_START
{
  "tasks": [
    {"issue": 19, "depends_on": []},
    {"issue": 20, "depends_on": []},
    {"issue": 21, "depends_on": []},
    {"issue": 22, "depends_on": []},
    {"issue": 25, "depends_on": []},
    {"issue": 18, "depends_on": [19]},
    {"issue": 23, "depends_on": [18, 19]},
    {"issue": 27, "depends_on": [20]},
    {"issue": 28, "depends_on": [21, 22]},
    {"issue": 29, "depends_on": [20]},
    {"issue": 30, "depends_on": [22]},
    {"issue": 31, "depends_on": [20]}
  ],
  "skip": [
    {"issue": 24, "reason": "not in pending issues list"},
    {"issue": 26, "reason": "not in pending issues list"}
  ]
}
SPRINT_PLAN_END
