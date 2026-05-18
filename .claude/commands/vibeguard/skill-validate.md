---
name: "VibeGuard: Skill Validate"
description: "Gate proposed skills with with/without repair and regression evidence"
category: VibeGuard
tags: [vibeguard, skill, validation, eval]
argument-hint: "--proposed-skill <SKILL.md> --baseline-trajectories <jsonl> [--held-out <jsonl>]"
---

**Core Concept**
- A proposed skill is an intervention, not just documentation.
- Accept it only after measuring `without_skill` vs `with_skill` on recorded scenarios.
- Keep facts separate from judgment: repairs, regressions, stale evidence, and unrelated-task regressions are explicit.

**Minimum JSONL Schema**

Each nonblank line in the baseline or held-out file is one scenario:

```json
{
  "scenario_id": "incident-1",
  "scenario_type": "target | unrelated",
  "without_skill": {"outcome": "success | failure"},
  "with_skill": {"outcome": "success | failure"},
  "scored_against_agent": "claude-opus-4-7",
  "scored_at": "2026-05-18",
  "notes": "optional human judgment notes"
}
```

**Steps**

1. Use `/vibeguard:learn` or a draft PR to propose a `SKILL.md`.
2. Record 3-5 scenarios:
   - At least one motivating incident the skill should repair.
   - At least two unrelated tasks the skill should not affect.
   - Optional held-out scenarios for the final verdict.
3. Run:
   ```bash
   python3 ~/vibeguard/scripts/skill_validate.py \
     --proposed-skill path/to/SKILL.md \
     --baseline-trajectories path/to/baseline.jsonl \
     --held-out path/to/held-out.jsonl \
     --current-agent <agent-or-model-id>
   ```
4. Treat the verdict as the gate:
   - `pass`: `repair > regression`, at least one repair, no regressions.
   - `needs_justification`: repair beats regression but at least one regression needs a written trade-off.
   - `advisory`: unrelated task regression exists; do not install as a hard instruction.
   - `stale`: evidence was scored against a different or too-old agent/model.
   - `fail`: no demonstrated repair, or regressions are greater than/equal to repairs.
5. Attach the emitted artifact path from `.vibeguard/skill-validate/` to the PR or final answer.

**Rules**
- Do not accept a new or changed skill on senior judgment alone.
- Do not hide regressions in summary prose; report the count and affected scenario IDs.
- Docs-only typo fixes can opt out; changes to constraints or decision rules need this gate.
