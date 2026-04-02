# AGENTS.md — VibeGuard Constraints for Codex/OpenAI Agents

> This file is equivalent to the VibeGuard rules of CLAUDE.md and adapts to the OpenAI Codex agent format.
> Copy to the project root directory and the Codex agent will automatically read it.
> Scope = the entire subtree of the directory where this file is located, with increasing priority for deep AGENTS.md.

## Constraints

| ID | Rule |
|----|------|
| L1 | Before creating any file/class/function, search for existing implementations first |
| L2 | Python: snake_case. API boundaries: camelCase. No aliases |
| L3 | No silent exception swallowing. No `Any` in public signatures |
| L4 | No data = show blank. Never invent APIs or fields that don't exist |
| L5 | Only do what was asked. No extra improvements, comments, or abstractions |
| L6 | 1-2 files: implement directly. 3-5 files: preflight first. 6+: spec first |
| L7 | No AI markers. No force push. No secrets in commits |

## Negative Constraints (what does NOT exist here)

- This project does NOT use an ORM
- This project does NOT have a frontend framework
- This project does NOT use microservices
- There is NO "similar file" pattern — always extend existing code
- There is NO backward compatibility requirement — delete old code directly

## Verification

Before completing any task:
- Rust: `cargo check` then `cargo test`
- TypeScript: `npx tsc --noEmit` then project test command
- Go: `go build ./...` then `go test ./...`
- Python: `pytest`

## Architecture Layers

If `.vibeguard-architecture.yaml` exists, enforce dependency direction:
`Types → Config → Repo → Service → Runtime → UI` (one-way only)

## Fix Priority

security vulnerability > logic bug > data inconsistency > duplicate types > unwrap > naming

## Style

- Single file ≤ 200 lines — split if exceeded
- No hardcoded values (ports, URLs, configs)
- No backward compatibility layers
- Every fix must include a corresponding test
- Follow existing project patterns

## Guards

VibeGuard guards are in `guards/` directory. Run all checks:
```
bash guards/universal/check_code_slop.sh .
python3 guards/universal/check_dependency_layers.py .
python3 guards/universal/check_circular_deps.py .
```
