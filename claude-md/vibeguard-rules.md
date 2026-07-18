<!-- vibeguard-start -->
#VibeGuard — AI anti-hallucination rules

> __VIBEGUARD_RULE_COUNT__ rules total. Claude defaults to the compact L1-L7 layers + Key Detailed Rules table below; load matching native rule files on demand from `~/.vibeguard/installed/rules/claude-rules/` when path-specific depth is needed. Full/strict profiles may also front-inject native rule files from `~/.claude/rules/vibeguard/`. Codex sees the same compact table. Repo-specific facts belong in the repo-level `AGENTS.md`.

## Constraints (L1-L7 use rules, hooks, guards, and workflows)

| Layers | Rules |
|----|------|
| L1 | **Must search first** before creating a new one; there is no "Similar files can be created" |
| L2 | snake_case(API boundary camelCase); alias does not exist |
| L3 | Disable silent swallowing of exceptions; there is no public method of Any type |
| L4 | No data = blank; no undeclared API/field exists |
| L5 | Just do what is asked; there is no "easy improvement" |
| L6 | Follow `workflows/references/routing-contract.md`: classify `work_surface`, then choose `execute_direct` / `plan_first` / `clarify_first`, plus the shared handoff fields |
| L7 | AI tag does not exist / force push / key submission |

## Chat Contract

Compact Chat Contract: progress updates, concise answers, plain formatting.

- Progress updates: for non-trivial or tool-heavy work, send a short update at start, after discovery, before edits, after verification, and when blocked.
- Default verbosity: keep answers concise by default; use short paragraphs for simple tasks and expand only when the work is complex or the user asks for depth.
- Formatting: use Markdown only when it helps; prefer prose first, flat bullets only for natural lists, and avoid decorative structure.
- Work surface: classify the request as `code_execution`, `writing_research`, or `chat_support` before applying workflow routing.
- Writing/research: keep factual/source verification and the requested tone, but do not force build/test/changed-files/PR-readiness/root-cause framing unless code, generated site content, or repository files are edited.

## Context · Validation

- Corrected 2 times → `/clear`
- **Must be preserved after Compaction**: (1) List of modified files (2) Constraint set/SPEC (3) Test command (4) Key decisions (5) Current priority (6) L1-L7 rule summary
- **Must be re-read after Compaction**: ongoing preflight constraint set or exec-plan file (if any)
- Before completion: Rust `cargo check` / TS `npx tsc --noEmit` / Go `go build ./...`
- Before submission: Rust `cargo test` / TS project test / Go `go test ./...` / Python `pytest`

## Four elements of the task (ask proactively when there are vague requirements)

| Elements | Questions |
|------|------|
| Goal | What to change/build? |
| Context | Which files/documents/errors are relevant? |
| Constraints | What standards/architectures/conventions must be followed? |
| Done-when | What conditions prove completion? |

## Workflow maturity ladder

**Manual** → After verification → **Skill** → After stable and reliable → **Automation**

- Manual phase: execute directly in the dialog, adjust until reliable
- Skill stage: packaged as SKILL.md, reusable, called by `/skill-name`
- Automation stage: Add scheduled scheduling (launchd/cron) without manual triggering

Rule: Workflows without manual validation are prohibited from direct automation.

## Order

`preflight` prevention · `check` verification · `review` review · `cross-review` confrontation · `build-fix` build · `learn` evolution · `interview` interview · `exec-plan` long cycle · `gc` cleanup · `stats` statistics
(prefix `/vibeguard:`)

## Priority

Security > Logic > Data Splitting > Repeating Types > Unwrap > Naming

## Key Detailed Rules (full set in `rules/claude-rules/**`)

<!-- vibeguard-generated-compact-rules:start -->
| ID | Severity | Rule |
|----|----------|------|
| U-16 | Guideline | Keep file size under control: 200-400 lines typical, 800 lines hard ceiling. Files above 800 must be split. |
| U-17 | Strict | Handle errors completely. Do not swallow exceptions silently. |
| U-22 | Strict | New code minimum 80% line coverage; critical paths 100%. |
| U-25 | Strict | Fix build failures first before any other edit; do not add new code while build is red. |
| U-26 | Strict | Declaration-execution completeness: declared Config / Trait / persistence layers must be wired into startup. |
| U-29 | Strict | No silent degradation: errors causing user-visible missing data or wrong output must `error` or raise, not `warning` + fallback. |
| W-01 | Strict | No fixes without root cause: reproduce first, then form one hypothesis, then fix. |
| W-02 | Strict | After 3 consecutive failed fixes on the same problem, stop and challenge the hypothesis or architecture. |
| W-03 | Strict | Verify before claiming completion: produce fresh command output proving the claim. |
| W-12 | Strict | Protect test integrity: fix production code, never weaken assertions or tamper with test infrastructure. |
| W-14 | Strict | Parallel agents must have explicit, disjoint file ownership; no shared writable file. |
| W-16 | Strict | Verification commands must come from this session. "Earlier passed" / "should work" do not count. |
| SEC-01 | Critical | No SQL / NoSQL / OS command injection: use parameterized queries and array argument lists. |
| SEC-02 | Critical | No hardcoded keys, credentials, or API tokens. Load from env / secret manager. |
| SEC-11 | Strict | AI-generated code carries higher security risk; mandatory human review for auth, payments, secrets, `innerHTML` / `eval` / `exec`. |
| SEC-13 | Strict | High-context files (`AGENTS.md`, `CLAUDE.md`, `.claude/settings*.json`, hooks) must not be silently modified by dependencies or generators. |
<!-- vibeguard-generated-compact-rules:end -->
<!-- vibeguard-end -->
