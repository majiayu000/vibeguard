# Canonical Directory Guidance

This file is the single editable source for repository-scoped `CLAUDE.md`
guidance. Do not edit the generated files directly. After changing a section,
run `python3 scripts/generate_directory_guidance.py` and commit the source and
generated outputs together.

The marker path is the generated repository-relative output. The generator
accepts only the allowlisted `CLAUDE.md` paths below and fails on missing,
duplicate, nested, mismatched, or unsafe sections.

<!-- directory-guidance:guards/CLAUDE.md:start -->
# guards/ directory

Language guard shell scripts are compatibility entrypoints. Detection belongs
in `vibeguard-runtime scan <language> <rule> <path>`; do not add detection,
diff parsing, or fallback scanners to shell.

## Go guards

| Script | Rule ID | Detection content |
|------|---------|----------|
| `guards/go/check_error_handling.sh` | GO-01 | Unchecked error return value assigned to `_` |
| `guards/go/check_goroutine_leak.sh` | GO-02 | Goroutine without an exit mechanism |
| `guards/go/check_defer_in_loop.sh` | GO-08 | Resource-releasing `defer` inside a loop |

## Rust guards

| Script | Rule ID | Detection content |
|------|---------|----------|
| `guards/rust/check_unwrap_in_prod.sh` | RS-03 | `unwrap()` or `expect()` in non-test code |
| `guards/rust/check_duplicate_types.sh` | RS-05 | Types duplicated across crates |
| `guards/rust/check_nested_locks.sh` | RS-01 | Nested locks with deadlock risk |
| `guards/rust/check_workspace_consistency.sh` | RS-06 | Cross-entry path inconsistency |
| `guards/rust/check_single_source_of_truth.sh` | RS-12 | Split task or state sources of truth |
| `guards/rust/check_semantic_effect.sh` | RS-13 | Action semantics and side effects disagree |
| `guards/rust/check_taste_invariants.sh` | TASTE-* | Harness code-taste invariants |
| `guards/rust/check_declaration_execution_gap.sh` | RS-14 | Declared config bypassed at startup |

All language scripts source their local `runtime-shim.sh` and call
`run_runtime_guard`. Each `common.sh` is a deprecated compatibility entrypoint.

RS-03 must exclude independent Rust test files and code below an inline
`#[cfg(test)]` module boundary. Pre-commit mode scans only added diff lines;
standalone audit mode performs a full scan. Intentional non-recoverable uses
require an inline `// vibeguard:allow` comment.

Output format:

```text
[LANG-XX] file:line: problem description. Repair: specific repair method
```
<!-- directory-guidance:guards/CLAUDE.md:end -->

<!-- directory-guidance:hooks/CLAUDE.md:start -->
# hooks/ directory

AI coding-agent hook scripts run around tool operations. Claude Code, Codex
CLI, and the opt-in Gemini CLI BeforeTool adapter are supported.

## Hook inventory

<!-- hooks-manifest-table:start -->
| Documentation | Trigger Timing | Responsibilities | Codex |
|------|----------|------|-------|
| `log.sh` | Used by other hook sources | Log module, providing shared functions such as vg_log, JSON parsing, source code judgment, etc. | - |
| `circuit-breaker.sh` | Checked by other hook sources | Circuit breaker library: CLOSED to OPEN to HALF-OPEN state machine, CI guard, stop_hook_active. | - |
| `run-hook-codex.sh` | Codex wrapper | Codex output format adapter (decision:block to permissionDecision:deny). | - |
| `run-hook-gemini.sh` | Gemini wrapper | Gemini BeforeTool routing and output adapter (decision:block to decision:deny). | - |
| `pre-bash-guard.sh` | PreToolUse(Bash) | Intercept destructive local cleanup commands: dangerous rm -rf paths, git clean -f, and batch git checkout/restore .; force-push protection lives in the git pre-push hook. | native |
| `pre-edit-guard.sh` | PreToolUse(Edit) | Block editing of non-existent files (anti-hallucination). | native |
| `pre-write-guard.sh` | PreToolUse(Write) | Remind you to search for existing implementation before creating a new source code file. | native |
| `post-edit-guard.sh` | PostToolUse(Edit) | Detect quality problems after editing: unwrap, console.log, hard-coded path, Go error discard, oversized diff, repeated editing of the same file (churn), W-15 consecutive same-file edit loop. | native |
| `post-write-guard.sh` | PostToolUse(Write) | Detect duplicate definitions and files with the same name after creating a new file. | native |
| `analysis-paralysis-guard.sh` | PostToolUse(Read|Glob|Grep) | Detect excessive exploration without progress and prompt the agent to act. | unsupported |
| `count_active_constraints.sh` | SessionStart | Count effective task constraints loaded into agent context; warn over the U-32 budget in core/full profiles and hard-block in strict profile. | unsupported |
| `post-build-check.sh` | PostToolUse(Edit/Write) | Automatically run the build check corresponding to the language after editing. | native |
| `skills-loader.sh` | Manual optional | Optional first read prompt script; not registered to hooks by default. | unsupported |
| `stop-guard.sh` | Stop | Record uncommitted source code changes as a non-blocking Stop signal; emit a W-16 advisory when the session edited source files but ran no verification command. | native |
| `learn-evaluator.sh` | Stop | Collect metrics at the end of session, detect corrective signals, and suggest /learn when signals exist. | native |
| `pre-commit-guard.sh` | git pre-commit | Automatic guard before submission: U-16 staged baseline, quality check plus build check, timeout hard limit. | - |
| `git/pre-push` | git pre-push | Block non-fast-forward pushes, remote branch deletion, and force-like push options by default. | - |
<!-- hooks-manifest-table:end -->

`native` means deployed to `~/.codex/hooks.json`; `unsupported` means Codex
does not expose the needed event or tool surface; `-` means not applicable.
Codex namespaced hook names resolve through `run-hook-codex.sh` to canonical
hook files.

## Host deployment

```text
Claude Code                 Codex CLI                  Gemini CLI (opt-in)
~/.claude/settings.json     ~/.codex/hooks.json        ~/.gemini/settings.json
  ↓                           ↓                          ↓
run-hook.sh                 run-hook-codex.sh          run-hook-gemini.sh
  └───────────────────────────┴──────────────────────────┘
                    ~/.vibeguard/installed/hooks/*
```

All supported hosts share the installed hook snapshot. Record hook decisions
as `pass`, `warn`, `block`, `gate`, `escalate`, `correction`, or `complete`.
Unknown/manual callers must use `client: "unknown"`; never silently attribute
them to a supported host.

Shared hook functions belong in `log.sh`, and events go through `vg_log`.
Configured production hook paths must stay Python-free. Use the Rust runtime
for structured parsing, policy, and adapters; Python is limited to tests, CI,
evaluation, install support, and inactive compatibility tools. When adding a
hook, check whether each host exposes the event and matcher needed to deploy it.
<!-- directory-guidance:hooks/CLAUDE.md:end -->

<!-- directory-guidance:rules/CLAUDE.md:start -->
# rules/ directory

VibeGuard rule files define inspection standards by language and domain.

| Prefix | Realm | Example |
|------|------|------|
| `U-XX` | Universal | U-11 hardcoded paths |
| `RS-XX` | Rust | RS-03 unwrap/expect |
| `TS-XX` | TypeScript/JavaScript | TS-01 any abuse |
| `PY-XX` | Python | PY-01 naming convention |
| `GO-XX` | Go | GO-01 error handling |
| `SEC-XX` | Security | SEC-01 key disclosure |

`rules/claude-rules/**` is the canonical English source. Author rule changes
there first. Top-level `rules/*.md` and `docs/rule-reference.md` are generated
with `python3 scripts/generate_rule_docs.py`.

Each rule needs an ID and name, severity, inspection description, specific
repair guidance, and a FIX/SKIP judgment matrix.
<!-- directory-guidance:rules/CLAUDE.md:end -->

<!-- directory-guidance:scripts/CLAUDE.md:start -->
# scripts/ directory

Scripts are grouped by responsibility; search the existing group before adding
a new entrypoint.

| Path | Responsibility |
|------|----------------|
| `setup/` | Public installation, checks, cleanup, and host targets |
| `ci/` | CI and static contract validators |
| `verify/` | Local compliance and freshness checks |
| `gc/` | Log, worktree, and scheduled cleanup |
| `metrics/` | Metrics collection and Prometheus export |
| `release/` | Deterministic release payload construction |
| `constraints/` | Constraint inventory and recommendations |
| `doctors/` | Installation and host diagnostics |
| `lib/` | Shared install and configuration helpers |

Common maintainer entrypoints include `stats.sh`, `health-report.py`,
`hook-health.sh`, `quality-grader.sh`, `project-init.sh`,
`authorized-discard.py`, `live_truth.py`, and `skill_validate.py`. Keep errors
visible, preserve dry-run behavior where documented, and put generated or
session-local output under the ignored locations defined by
`docs/reference/process-artifacts.md`.

The configured hook production path is Rust-first and Python-free. Python
scripts may support tests, CI, evaluation, installation, and maintainer tools,
but must not be introduced into configured hook execution.
<!-- directory-guidance:scripts/CLAUDE.md:end -->

<!-- directory-guidance:claude-md/CLAUDE.md:start -->
# claude-md/ directory

This directory contains the shared global contract and host-specific additions
injected into Claude Code and Codex.

1. `vibeguard-rules.md` contains the shared core and managed markers.
2. `vibeguard-claude.md` and `vibeguard-codex.md` contain host-only guidance.
3. `python3 scripts/generate_rule_docs.py` composes the generated host blocks.
4. `setup.sh` injects the matching block between `<!-- vibeguard-start -->` and
   `<!-- vibeguard-end -->`, preserving content outside the managed region.

To change injected rules, edit `rules/claude-rules/**` first, including the
`**Compact guidance:**` field when selected for compact injection. Regenerate
the rule docs, rerun setup, and validate both Claude and Codex rendered blocks.
The updated contract becomes active in a new host session after setup reruns.
<!-- directory-guidance:claude-md/CLAUDE.md:end -->
