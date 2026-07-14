---
name: specrail-install
description: Use when installing, updating, verifying, or adopting SpecRail for agents. Guides local Codex skill installation, global AGENTS.md guidance setup, repository adoption planning, dry-run-first verification, and explicit human authorization boundaries.
---

# SpecRail Install

Use this skill for agent-facing SpecRail setup. The skill is the entrypoint; CLI
tools are deterministic helpers the agent runs after selecting the setup route.

## Routes

- `doctor`: inspect current setup without writing files.
- `install_local_skills`: install or update local Codex skills.
- `install_global_guidance`: add or update global agent guidance.
- `adopt_repo`: plan or perform SpecRail pack adoption in a target repository.

## Steps

1. Identify the route from the user's request. If the user only asks whether
   SpecRail is installed, choose `doctor`.
2. Read the active repo instructions and `AGENT_USAGE.md`.
3. Run dry-run checks before any write:

```sh
python3 tools/install_codex_skills.py --repo .
python3 checks/check_workflow.py --repo .
```

4. For `install_local_skills`, use `--apply` only when the user explicitly asks
   to install or update local Codex skills:

```sh
python3 tools/install_codex_skills.py --repo . --apply
```

5. For `install_global_guidance`, update `~/.codex/AGENTS.md` only after an
   explicit user request. Use a small managed SpecRail section or update the
   existing SpecRail section; do not rewrite unrelated global instructions.
6. For `adopt_repo`, first report the target repo, files to copy, files that
   would be preserved, and validation commands. Do not copy pack files into a
   target repo unless the user explicitly asks.
7. Verify after writes:

```sh
python3 checks/check_workflow.py --repo .
python3 -m pytest -q
```

When local skills were installed, also verify installed `SKILL.md` hashes match
`skills-lock.json`.

## Boundaries

- Dry-run is the default.
- Do not install local skills, modify global `AGENTS.md`, copy pack files into a
  repo, create remote issues or PRs, add labels, approve, merge, or bypass
  maintainers unless the user explicitly asks for that action.
- Keep repo adoption separate from local agent setup.
- Report which layer changed: local skills, global guidance, target repo pack,
  or none.

## When to Activate

- Activate this route only when the request matches the skill description and the SpecRail router selected it.
- Use it after loading repository instructions, workflow policy, and the current user-authorized scope.

## Red Flags

- Required issue, spec, PR, runtime, or review evidence is missing or stale.
- A proposed action would bypass an offline gate, CI, review, or human authorization.
- The route would ignore configured paths, duplicate an artifact, or cross the requested scope.

## Checklist

- [ ] Confirm the route, configured paths, locale, and authorization mode before writes.
- [ ] Search first and record missing evidence or human gates without inventing state.
- [ ] Run the focused validator and report its exact decision or blocker.
