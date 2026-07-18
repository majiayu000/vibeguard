# AGENTS.md — VibeGuard Starter Constraints for Codex/OpenAI Agents

> This starter carries the compact VibeGuard contract for Codex-style agents. It is not a replacement for the full Claude rule tree.
> Copy it to a project root directory, then add project-specific facts for that repository.
> Scope = the entire subtree of the directory where this file is located, with increasing priority for deep AGENTS.md.

## Chat Contract

Compact Chat Contract: progress updates, concise answers, plain formatting.

- Progress updates: for non-trivial or tool-heavy work, send a short update at start, after discovery, before edits, after verification, and when blocked.
- Default verbosity: keep answers concise by default; use short paragraphs for simple tasks and expand only when the work is complex or the user asks for depth.
- Formatting: use Markdown only when it helps; prefer prose first, flat bullets only for natural lists, and avoid decorative structure.
- Work surface: classify the request as `code_execution`, `writing_research`, or `chat_support` before applying workflow routing.
- Writing/research: keep factual/source verification and the requested tone, but do not force build/test/changed-files/PR-readiness/root-cause framing unless code, generated site content, or repository files are edited.
- Style: avoid stock contrast framing such as "not X, but Y" / "不是 X，而是 Y" unless the user asks for punchy opinion writing.

## Operating Principles

- Search before adding files, functions, rules, hooks, workflows, or tests.
- Do not commit secrets, credentials, tokens, or private keys.
- Do not use AI marker tags in commits, PRs, comments, generated files, or shipped text.
- Do not force push unless the human explicitly authorizes the exact branch and reason.
- Fail loudly on user-visible missing data, wrong output, malformed inputs, or broken validation.

## Constraints

| ID | Rule |
|----|------|
| L1 | Before creating any file/class/function, search for existing implementations first |
| L2 | Python: snake_case. API boundaries: camelCase. No aliases |
| L3 | No silent exception swallowing. No `Any` in public signatures |
| L4 | No data = show blank. Never invent APIs or fields that don't exist |
| L5 | Only do what was asked. No extra improvements, comments, or abstractions |
| L6 | Follow `workflows/references/routing-contract.md`: classify `work_surface`, then choose `execute_direct`, `plan_first`, `clarify_first`, and the shared handoff fields |
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

## Routing

Follow `workflows/references/routing-contract.md`:
- Classify `work_surface` first: `code_execution`, `writing_research`, or `chat_support`.
- `execute_direct`: clear, low-risk, local change with known verification.
- `plan_first`: multi-file, architectural, migration, or ambiguous implementation path.
- `clarify_first`: missing goal, context, constraints, or done-when would make execution unsafe.

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
