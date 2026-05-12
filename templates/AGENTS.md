# AGENTS.md — VibeGuard Starter Constraints for Codex/OpenAI Agents

> This starter carries the compact VibeGuard contract for Codex-style agents. It is not a replacement for the full Claude rule tree.
> Copy it to a project root directory, then add project-specific facts for that repository.
> Scope = the entire subtree of the directory where this file is located, with increasing priority for deep AGENTS.md.

## Chat Contract

Compact Chat Contract: progress updates, concise answers, plain formatting.

- Progress updates: for non-trivial or tool-heavy work, send a short update at start, after discovery, before edits, after verification, and when blocked.
- Default verbosity: keep answers concise by default; use short paragraphs for simple tasks and expand only when the work is complex or the user asks for depth.
- Formatting: use Markdown only when it helps; prefer prose first, flat bullets only for natural lists, and avoid decorative structure.

## Constraints

| ID | Rule |
|----|------|
| L1 | Before creating any file/class/function, search for existing implementations first |
| L2 | Python: snake_case. API boundaries: camelCase. No aliases |
| L3 | No silent exception swallowing. No `Any` in public signatures |
| L4 | No data = show blank. Never invent APIs or fields that don't exist |
| L5 | Only do what was asked. No extra improvements, comments, or abstractions |
| L6 | Follow `workflows/references/routing-contract.md`: `execute_direct`, `plan_first`, `clarify_first`, and the shared handoff fields; delegated work follows `workflows/references/delegation-contract.md` |
| L7 | No AI markers. No force push. No secrets in commits |

## Project Constraints To Fill In

- Record repo-specific facts here, such as architecture layers, storage boundaries, supported runtimes, and test commands.
- Do not put repo-specific facts into the global `~/.codex/AGENTS.md` block.
- There is no "similar file" shortcut. Search for existing code and extend it when the existing contract supports the change.
- Do not add backward compatibility layers unless the project contract or migration plan requires them.

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

## Code Style

- Keep file size under control: 200-400 lines typical, 800 lines hard ceiling
- No hardcoded values (ports, URLs, configs)
- Every fix must include a corresponding test
- Follow existing project patterns

## Guards

VibeGuard guards are in `guards/` directory. Run all checks:
```
bash guards/universal/check_code_slop.sh .
python3 guards/universal/check_dependency_layers.py .
python3 guards/universal/check_circular_deps.py .
```
