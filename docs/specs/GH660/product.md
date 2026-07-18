# Product Spec — remove strategic-compact skill and stale skill-name references

Linked Issue: #660
complexity: small

## Goals

Retire `skills/strategic-compact/` and stop pointing users at the external
`claude-md-split` skill by name from repo guidance (it is not part of this
repo's install surface).

## Non-Goals

Removing or changing any other skill; changing W-19 thresholds or the
doc-overload guard's detection logic (message wording only); removing or
changing the W-11 `VIBEGUARD_SUPPRESS_PARALYSIS` downgrade path.

## Behavior Invariants

- B-001: `skills/strategic-compact/` no longer exists, and the
  `skills-core` entry in `schemas/install-modules.json` contains neither its
  path nor its retired name; the install manifest contract test still passes.
- B-002: Repo guidance (`rules/claude-rules/common/workflow.md` W-19 fix
  section, `guards/universal/check_doc_overload.sh` messages) describes the
  split action ("keep a short index and move topic detail into
  `.claude/references/`") without naming the `claude-md-split` skill.
- B-003: On the next setup or clean operation, the existing retired-manifest
  cleanup removes a previously tracked Claude
  `~/.claude/skills/strategic-compact` symlink after its manifest entry is
  removed. It preserves untracked or non-symlink user paths. No copied Codex
  installation is removed because `strategic-compact` has never belonged to
  the `skills-codex-core` manifest target.

## Boundary Checklist

| Category | Verdict (covered: B-xxx / N/A + reason) |
| --- | --- |
| Empty / missing input | N/A — no new input or payload is introduced |
| Error / failure paths | covered: B-001 — stale manifest references fail contract validation |
| Authorization / permission | N/A — retirement does not expand permissions |
| Concurrency / race | N/A — manifest evaluation and tracked-link cleanup are serialized setup steps |
| Retry / idempotency | covered: B-003 — repeated cleanup leaves the retired link absent |
| Illegal state transitions | covered: B-003 — only a tracked retired symlink is removed |
| Compatibility / migration | covered: B-001, B-003 |
| Degradation / fallback | covered: B-003 — an untracked or non-symlink path is preserved visibly, not deleted |
| Evidence / audit integrity | covered: B-001, B-002, B-003 |
| Cancellation / interruption | N/A — rerunning setup repeats the idempotent cleanup |

## Acceptance

`bash tests/test_manifest_contract.sh` and `bash tests/test_setup.sh` pass. The
retired-link assertions live in `tests/setup/syntax_manifest_tests.sh`, which
is sourced by the setup harness. The reference scan accepts only
`rg` exit 1 as "no match" and preserves scanner errors:
`if rg 'strategic-compact|claude-md-split' rules guards schemas skills; then
exit 1; else test $? -eq 1; fi`.
