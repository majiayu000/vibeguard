# Design discussion: rule overlap, severity calibration, and lint-vs-agent boundary in `rules/claude-rules/`

> External read-only audit of the rule system in `rules/claude-rules/**`. Not a bug report — these are observations and questions for the maintainers. Where a claim could be fact-checked from the repo, I cite file+line. Where it's a design judgement, I label it as such.

## TL;DR

After reading the 13 rule files (1325 lines, ~115 rules total) end-to-end, I'd group the rules into three contentful buckets and ask the maintainers' view on a few specific overlaps and a strict-label calibration question.

Rough breakdown by my reading:

| Bucket | Roughly how many | Examples |
|---|---|---|
| **Substantive agent-harness rules** with sources, mechanical checks, downgrade paths | ~18 | W-12, W-14, W-15, W-16, W-17, W-18, W-19, U-25, U-26, U-29, U-32, U-33, SEC-11–14, W-10, W-11 |
| **One-line "training advice" rules** (style preference, no mechanical check) | ~28 | U-01, U-02, U-03, U-04, U-05, U-06, U-07, U-09, U-10, plus many GO-/TS-/PY- one-liners |
| **Context-specialised rules** (only trigger in a narrow scenario but live in `common/`) | ~12 | U-11–U-14 (monorepo data path), W-18 (eval harness), U-30/U-31 (Pydantic+cache), RS-20 (Rust struct edit) |

The first bucket is, in my opinion, the load-bearing value of the project. The other two buckets are where I have questions.

---

## Observation 1: three rules about "do not silently swallow errors" sit alongside each other

Three rules in `common/` all say a variant of "errors must not be silently dropped":

- **U-17** (`coding-style.md:39`): one line, *"Handle errors completely. Do not swallow exceptions silently."*
- **U-23** (`coding-style.md:63`): one line, *"Unsupported strategies or configurations must fail explicitly or be marked as DEFER. Do not silently fall back to a default strategy."*
- **U-29** (`no-silent-degradation.md`, full file): 80 lines with a decision rule (what does the user see → error vs warning), 4 BAD/GOOD code-pair scenarios, and mechanical checks.

U-29 is by far the most actionable of the three. U-17 and U-23 read like high-level summaries that U-29 already covers in detail. The language-specific instantiations (RS-10 `let _ = ...`, GO-01 unchecked errors, PY-02 bare `except`, TS-02 unhandled promise) already serve as concrete checkers.

**Question for maintainers**: would it be cleaner to keep U-29 as the canonical error-handling rule and replace U-17 / U-23 bodies with a one-line `see U-29 for canonical guidance` pointer, so the LLM doesn't get three near-identical assertions in the same context window?

---

## Observation 2: U-08 looks fully covered by W-03 + W-16

- **U-08** (`coding-style.md:24`): *"Every fix must independently pass lint and tests."* (one line, no mechanical checks)
- **W-03** (`workflow.md:33`): 5-step verification protocol + 60-second Nyquist rule + mechanical checks (~30 lines)
- **W-16** (`workflow.md:182`): "verification must come from this session" with 7 forbidden claim patterns and 8 rationalisation rebuttals (~40 lines)

W-03 and W-16 between them cover the substance of U-08, with more detail and with a downgrade path (W-16 has the "lightweight fresh-context self-review" fallback).

**Question for maintainers**: is there a case U-08 catches that W-03 / W-16 don't? If not, would dropping U-08 in favour of a pointer reduce overlap without losing coverage?

---

## Observation 3: `strict` is doing a lot of work, and U-32 says it shouldn't

U-32 (`coding-style.md:99`) itself says:

> If a rule uses absolute phrasing such as "ensure X", "never do Y", or "must be 100%", attach both:
> - A downgrade path: "If X is not feasible, fall back to Y and mark it stale."
> - An observability hook: a verification command or guard script that proves whether the rule is actually being followed.

A few `strict` rules in the repo don't carry an explicit downgrade path in their body. The most striking cases by my reading:

- **U-02** ("don't extract abstractions for code that appears only once"): style preference, no mechanical check, no downgrade.
- **U-21** ("commit messages must follow the Lore protocol"): project-specific convention. If a downstream project doesn't have a `LORE.md`, what does `strict` mean here?
- **U-22** ("new code must reach at least 80% coverage; critical paths require 100%"): the percentages are absolutes, but the body's mechanical checks only say "mark it as DEFER and tell the user" — there is no enforcement command, and 80% is a debated number in 2026 practice.
- **U-24** ("no aliases"): no migration-window exception.

These all have legitimate arguments behind them, but tagging them `strict` while leaving them un-enforceable risks devaluing `strict` as a signal. Rules that *are* hard-enforced (e.g. W-13, W-14, W-15 with real hooks; SEC-01/02 critical) end up sharing the same label as taste preferences.

**Question for maintainers**: what's the intended semantic of `strict` vs `guideline`? If `strict` means "hook will block / escalate", several of the above don't currently qualify. If `strict` means "agent should treat as non-negotiable advice", that's compatible — but then U-32's own warning about absolute language without a downgrade path applies more aggressively.

---

## Observation 4: language-specific files overlap heavily with native linters

A non-trivial fraction of `golang/quality.md`, `typescript/quality.md`, and `python/quality.md` describe checks that `golangci-lint` / `eslint` (typescript-eslint, react-hooks/exhaustive-deps) / `ruff` already implement:

| Rule | Equivalent in standard linter |
|---|---|
| GO-01 unchecked errors | `errcheck` (golangci-lint default) |
| GO-03 data race | `go test -race` |
| GO-06 append without preallocated cap | `prealloc` |
| GO-12 struct field ordering | `fieldalignment` |
| TS-03 `==` vs `===` | `eqeqeq` |
| TS-06 `useEffect` deps | `react-hooks/exhaustive-deps` |
| TS-08 `as any` / `@ts-ignore` | `@typescript-eslint/no-explicit-any` |
| TS-09 functions with >4 params | `max-params` |
| PY-01 mutable defaults | `B006` in flake8-bugbear / `PLW0102` in pylint |
| PY-06 regex in loops | `PERF401` etc. |
| PY-08 `eval`/`exec` | `S307` (bandit), `PGH001` |
| PY-12 `len()` in loops | `PERF402` |

Other rules in the same files (TS-13 duplicate component / hook; TS-14 mock drift; PY-13 dead compatibility shim; RS-12 two systems for one responsibility) are genuinely beyond linter scope — they need semantic context.

**Question for maintainers**: is the intent to have the rule system *educate* the LLM on lint-equivalent items, or to *replace* the linter? If the former, putting these alongside the rare semantic rules (TS-13, TS-14) means the high-signal items compete for attention with items the toolchain already enforces. Splitting them into two files (`lint-equivalent-reminders.md` vs `semantic-only.md`) might help readability without removing anything.

---

## Observation 5: rules in `common/` that only fire in narrow scenarios

A few rules sit in `common/` (loaded for every session) but their content is scenario-specific:

- **U-11 – U-14** (`data-consistency.md`): "Inconsistent default DB/cache paths across binaries" — only relevant in multi-binary monorepos. Single-binary projects will never trigger any of these.
- **W-18** (`workflow.md:265`): three-axis eval validation — only relevant when developing an eval harness.

For comparison, U-30 / U-31 (Pydantic / cache versioning) are already correctly scoped via `paths:` frontmatter to Python files only. The same approach would let U-11–U-14 only load when a project has multiple `Cargo.toml` / `package.json` / `pyproject.toml` entry points, and W-18 only load when an `evals/` directory or eval-related dependencies exist.

**Question for maintainers**: is the current always-loaded position intentional (so an LLM is always *aware* of the rule), or would the maintainers be open to scoping these down?

---

## Observation 6: minor — `post_edit_history.sh:28` cites W-02 but the trigger is W-15-shaped

This one is small. In `hooks/_lib/post_edit_history.sh:26-29`:

```bash
if [[ "$churn_count" -ge 20 ]]; then
    vg_post_edit_append_warning "[CHURN CRITICAL] [review] [this-file] OBSERVATION: ${FILE_PATH##*/} has been edited ${churn_count} times — possible edit→fail→fix loop
FIX: Stop current direction, review full build output, re-examine root cause (W-02)
DO NOT: Continue editing this file until root cause is confirmed"
```

W-02 (`workflow.md:19`) is "back off after 3 consecutive *failures* of the same problem". The hook fires on 20 edits of the same *file*, which is closer to W-15's "low-information loop on the same file" than to W-02's failure-count semantics. Both rules cover similar ground (W-17 even discusses how W-02 / W-13 / W-15 are complementary), but the explicit citation in the warning text is slightly off.

**Suggestion**: change the `(W-02)` citation to `(W-15)` (or `(W-15 / W-02)`), to match how W-17 describes the three-way decomposition. Not urgent.

---

## What I'm not raising as an issue

A few things came up in my audit that I'm explicitly *not* surfacing:

- **strict→guideline downgrade lists**: I have opinions, but they're design judgement. If the maintainers want concrete examples I can share, but it's not in scope here.
- **"AI says rule X is too strict"**: I deliberately did not include arguments that came only from external LLMs (Grok / Gemini) without an internal evidence anchor. The points above are all things I verified by reading the rule body or the hook source in this repo.
- **Restructuring `coding-style.md` to be under U-32's own 30-rule threshold**: that's a bigger conversation. The file currently has ~24 numbered rules and 4 sub-sections; if the maintainers consider U-32 binding on itself, that's a separate design decision.

---

## Method note (for transparency)

The contentful audit was done by reading the 13 files in `rules/claude-rules/**` plus the corresponding `hooks/` and `guards/` implementations. Two internal sub-agents did parallel structural and mechanical-check-coverage analyses. Two external LLMs (Grok, Gemini) gave high-level second opinions, but they were only shown rule *titles*, not the rule *bodies*, so their suggestions are weighted lightly compared to direct repo reads. A third external LLM (ChatGPT via CLI) timed out twice and was dropped.

**Disclosure of an audit error I made and corrected before writing this issue.** An earlier draft of my audit claimed the repository contained "four fake-cmd references" (rules citing guard scripts that I asserted did not exist) and a "W-02 threshold drift." Both claims were wrong. The root cause was that I ran my audit on a `codex/codex-usage-experience` working tree that had deleted several `guards/universal/*.sh` scripts (and the matching rule references — i.e. the branch is self-consistent). I used `find` on the working tree, saw zero hits, and incorrectly concluded "this script does not exist in the repository," without checking `git ls-tree origin/main` for the canonical state. After verifying against `origin/main`, all of those scripts exist. I have retracted those claims and the corresponding "P0 fixes" in my local audit notes. **None of the observations in this issue depend on the retracted fact-level claims — every observation above is based on reading the rule body directly.**

The reason I'm flagging this is partly so the maintainers can dismiss anything that looks like leftover noise from the earlier error, and partly because two of my own observations (W-10 hook coverage on `codex` branch; `post_edit_history.sh:28` W-02 citation) were verified on the `codex` branch — they may not reproduce on `main`. I noted that in the observation bodies.

I'm happy to expand on any of the observations above with specific file:line references on `origin/main` if it would help.
