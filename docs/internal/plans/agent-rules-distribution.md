# SPEC: Codex Experience Remediation

- Date: 2026-05-05
- Status: P0-P2 implemented, P3 optional
- Owner: VibeGuard setup/runtime
- Scope: Codex CLI native hooks, AGENTS rule distribution, setup/check UX, regression tests
- Related files: `AGENTS.md`, `claude-md/vibeguard-rules.md`, `templates/AGENTS.md`, `scripts/setup/targets/codex-home.sh`, `scripts/setup/install.sh`, `scripts/lib/codex_hooks_json.py`, `hooks/run-hook-codex.sh`, `hooks/_lib/codex_adapter.sh`, `tests/test_setup.sh`, `tests/test_codex_runtime.sh`, `tests/test_hook_health.sh`

## Goal

Make VibeGuard's Codex experience accurate, observable, and repairable. After this remediation, a user should be able to run one status/check command and know whether Codex can see the rules, whether native hooks are installed and firing, which protection surface is actually covered, and what concrete repair command is needed if the install is dirty.

This SPEC replaces the earlier partial "Agent Rules Distribution" draft. The earlier P1 fix already injected VibeGuard rules into `~/.codex/AGENTS.md`; the remaining work is to remove misleading global context, tighten AGENTS hygiene checks, expose Codex status clearly, and close test gaps.

## Implementation Status

P0 is implemented:

- repo-level `AGENTS.md` now carries VibeGuard-local facts
- global injected rules no longer include repo-specific architecture facts
- `templates/AGENTS.md` is now a starter template and aligns with U-16
- `setup.sh --check` validates `~/.codex/AGENTS.md` structure and warns on unmanaged content outside the VibeGuard block
- setup tests cover dry-run behavior, install anchors, broken marker cases, unmanaged-content warnings, read-only checks, and clean preserving unmanaged content

P1-P2 are also implemented:

- `setup.sh --codex-status` provides a read-only Codex-focused status surface
- shared `~/.codex/config.toml` and `~/.codex/hooks.json` checksum drift is downgraded when semantic checks pass
- `hooks/run-hook-codex.sh` stays thin and writes diagnostics to `~/.vibeguard/codex-wrapper.jsonl`
- `scripts/codex-contract-check.sh` runs the Codex setup/status/runtime/health contract tests in one place

P3 remains optional: `codex debug prompt-input` proof is still version-gated and should be added only if the local Codex CLI keeps that debug surface stable.

## Non-goals

- Do not claim Claude Code parity for Codex native hooks.
- Do not add Edit/Write/Read native hook support unless Codex itself supports those events. VibeGuard may document the app-server wrapper as the full-surface alternative.
- Do not delete user-managed content from `~/.codex/AGENTS.md` automatically. Marker-external content is reported first; cleanup requires explicit setup/clean behavior or user confirmation.
- Do not rewrite the whole install system. Keep changes scoped to Codex-specific status, rule distribution, wrapper diagnostics, and tests.
- Do not introduce a new daemon, MCP server, ORM, front-end framework, or microservice.

## Facts

- `~/.codex/AGENTS.md` and `~/.codex/agents.md` were previously 0 bytes; when no repo-level `AGENTS.md` exists, Codex has no durable VibeGuard reasoning context.
- The current setup path injects `claude-md/vibeguard-rules.md` into `~/.codex/AGENTS.md` through `scripts/setup/targets/codex-home.sh`.
- Current Codex native hook support must be described as `PreToolUse(Bash)`, `PostToolUse(Bash)`, and `Stop(stop-guard/learn-evaluator)`.
- `scripts/lib/codex_hooks_json.py` generates `~/.codex/hooks.json` commands as `bash <wrapper> <vibeguard-*.sh>`, with matcher and timeout derived from `hooks/manifest.json`.
- `hooks/run-hook-codex.sh` sets `VIBEGUARD_CLI=codex` and `VIBEGUARD_AGENT_TYPE=codex`, then adapts Claude-style hook output to Codex output.
- The latest audit found that `~/.codex/AGENTS.md` can contain marker-external content after the managed block, while `setup.sh --check` still reports OK.
- `~/.codex/config.toml` and `~/.codex/hooks.json` are shared files that other tools may legitimately mutate; whole-file checksum drift can be noisy even when VibeGuard-managed semantics remain healthy.

## Inferences

- The product problem is not "Codex hooks do not run"; it is "users cannot easily tell which Codex surfaces are protected, and setup/check can overstate health."
- Global `~/.codex/AGENTS.md` should contain only cross-repo durable rules. Repo-specific facts such as "no ORM, no front-end framework, no microservices" belong in a repo-level `AGENTS.md`.
- Wrapper-level silent exits are acceptable for normal Codex UX only if there is a separate diagnostic path. Without that path, broken installs look like "VibeGuard did nothing."
- A Codex-specific contract gate is needed because generic local checks do not currently prove AGENTS visibility, native payload shape, or Codex status output.

## Requirements

### R1: Accurate Codex Capability Contract

Codex-facing output and docs must state the exact native support:

- `PreToolUse(Bash)` -> command approval guard via `vibeguard-pre-bash-guard.sh`
- `PostToolUse(Bash)` -> build/post-command feedback via `vibeguard-post-build-check.sh`
- `Stop` -> `vibeguard-stop-guard.sh` and `vibeguard-learn-evaluator.sh`
- `Edit`, `Write`, `Read`, `Glob`, `Grep`, and `analysis-paralysis` are not native Codex CLI hooks in this contract.
- Full edit/write/read quality coverage requires Claude Code or the Rust `vibeguard-runtime codex-app-server-wrapper` path.

Done-when:

- `setup.sh --check` prints the exact capability list.
- README and Codex rule text do not imply Claude Code parity.
- Tests assert the capability wording contains `PreToolUse(Bash)`, `PostToolUse(Bash)`, and `Stop`.

### R2: Rule Distribution Split

Codex rule content must be split by scope:

- Global `~/.codex/AGENTS.md`: cross-repo VibeGuard rules only.
- Repo-level `AGENTS.md`: VibeGuard repo facts and local constraints.
- `templates/AGENTS.md`: safe starter template for a project, not a VibeGuard repo fact dump.

Global content may include:

- Chat Contract
- L1-L7 summary
- Key U/W/SEC rules
- validation requirement
- Codex capability matrix

Global content must not include:

- "There is no ORM"
- "There is no front-end framework"
- "There are no microservices"
- any other current-repo architecture fact that would be false in another repo

Done-when:

- `claude-md/vibeguard-rules.md` or the new Codex injection source has no cross-repo-invalid project facts.
- VibeGuard repo root has an `AGENTS.md` carrying local repo constraints.
- `templates/AGENTS.md` no longer claims equivalence to full `CLAUDE.md` unless it actually carries the same contract.
- `templates/AGENTS.md` no longer conflicts with U-16.

### R3: AGENTS Hygiene and SEC-13 Check

`check_codex_home_installation` must validate managed AGENTS content structurally:

- file exists
- file is non-empty
- exactly one `vibeguard-start`
- exactly one `vibeguard-end`
- start appears before end
- managed block contains required anchors: `Chat Contract`, `L1`, `Key Detailed Rules`, `W-03`, `SEC-13`
- marker-external non-empty content is reported as WARN, with a short count and first suspicious line
- duplicate marker or missing end marker is FAIL

The check should not auto-delete marker-external content. Cleanup belongs to an explicit repair command or confirmed setup write.

Done-when:

- 0-byte `~/.codex/AGENTS.md` is reported as BROKEN.
- missing end marker is reported as BROKEN.
- duplicate start/end marker is reported as BROKEN.
- marker-external content is reported as WARN.
- valid managed-only content is OK.

### R4: Codex Status Command

Add a single status surface, either as `bash setup.sh --codex-status` or `bash scripts/setup/check.sh --codex`, that answers:

- Codex CLI path and version if available
- `~/.codex/AGENTS.md` hygiene status
- whether `~/.codex/hooks.json` has all VibeGuard-managed entries
- whether `[features].hooks = true`
- whether legacy VibeGuard MCP config remains
- installed wrapper path and executable status
- latest VibeGuard Codex event timestamp, hook, decision, and project root
- semantic drift summary for shared Codex files
- exact native capability list
- suggested repair command

This command must be read-only.

Done-when:

- Running the status command does not modify `~/.codex/*` or `~/.vibeguard/*`.
- Missing AGENTS, disabled `hooks`, deprecated `codex_hooks`, stale hooks, and no recent log events produce distinct messages.
- A healthy install reports "Codex native support: PreToolUse(Bash), PostToolUse(Bash), Stop".

### R5: Semantic Drift Instead of Whole-file Drift

For shared Codex files, `setup.sh --check` must prefer semantic checks over whole-file checksum failure:

- `~/.codex/config.toml`: OK if `hooks = true` and no legacy VibeGuard MCP block exists.
- `~/.codex/hooks.json`: OK if all VibeGuard-managed hooks are present with expected command, matcher, type, and timeout.
- Whole-file checksum mismatch may be INFO, not a red failure, when semantic checks pass.

Done-when:

- User edits unrelated Codex config but keeps `hooks = true`; status reports semantic OK and checksum INFO.
- A missing VibeGuard hook entry remains a WARN or FAIL.
- A malformed TOML/JSON remains BROKEN.

### R6: Wrapper Diagnostics Without Noisy Stdout

`hooks/run-hook-codex.sh` must keep normal pass paths silent, but expose installation failures through diagnostics:

- missing `~/.vibeguard/repo-path`
- missing installed hook directory
- missing target hook
- missing `codex_adapter.sh`
- non-namespaced hook name
- non-PreToolUse wrapped-hook nonzero
- PostToolUse invalid JSON

Default behavior should not spam Codex stdout. Use a diagnostic sink such as `~/.vibeguard/codex-wrapper.jsonl`, or emit only when `VIBEGUARD_DEBUG=1`.

Done-when:

- Existing pass-with-no-output tests still pass.
- Missing adapter can be diagnosed after the fact.
- PreToolUse failure remains fail-closed with `permissionDecision=deny`.

### R7: Native Payload Test Coverage

Tests must prove the native Codex contract, not only hand-built idealized payloads:

- AGENTS install/check/clean/idempotency
- AGENTS 0-byte, missing marker, duplicate marker, external content
- `hooks` semantic status plus `codex_hooks` deprecation status
- native Bash-shaped `PostToolUse` payload behavior
- `hook-health.sh` with `cli=codex` and `cli=claude` fixture rows
- `run-hook-codex.sh` wrapper diagnostics
- optional: `codex debug prompt-input` proves AGENTS content reaches prompt input without model call

Done-when:

- `tests/test_setup.sh` covers AGENTS injection and hygiene.
- `tests/test_codex_runtime.sh` covers native payload and wrapper diagnostics.
- `tests/test_hook_health.sh` covers CLI distribution.
- A Codex contract command runs the Codex-relevant tests in one place.

## Proposed File Changes

### P0: Fix User-visible Truth and Hygiene

- `claude-md/vibeguard-rules.md`
  - remove global project-specific facts
  - add Codex capability matrix
  - keep Key Detailed Rules compact
- `AGENTS.md`
  - add repo-level VibeGuard constraints: no ORM, no front-end framework, no microservices, setup/test commands, routing contract pointer
- `templates/AGENTS.md`
  - reword as starter template
  - remove conflicting `<=200 lines` hard rule or align it with U-16
- `scripts/setup/targets/codex-home.sh`
  - strengthen AGENTS check
  - print exact native capability list
- `README.md`
  - document global AGENTS injection and native capability limits

Verification:

- `bash setup.sh --check`
- `bash tests/test_setup.sh`
- `git diff --check`

### P1: Add Codex Status and Semantic Drift

- `scripts/setup/check.sh`
  - add Codex-only status mode or factor a helper called by `--check`
- `scripts/setup/targets/codex-home.sh`
  - expose reusable status functions
- `scripts/lib/codex_config_toml.py`
  - keep semantic `check-codex-hooks`
- `scripts/lib/codex_hooks_json.py`
  - keep semantic managed-entry checker
- `scripts/local-contract-check.sh` or a new Codex contract script under `scripts/`
  - run Codex contract tests

Verification:

- `bash setup.sh --check`
- the Codex contract command created in P1
- `bash tests/test_manifest_contract.sh`

### P2: Wrapper Diagnostics and Native Payload Coverage

- `hooks/run-hook-codex.sh`
  - add diagnostic sink for silent failure paths
- `hooks/_lib/codex_adapter.sh`
  - keep fail-closed PreToolUse adapter behavior
- `tests/test_codex_runtime.sh`
  - add missing-adapter/missing-hook diagnostic tests
  - add native Bash-shaped PostToolUse payload fixture
- `tests/test_hook_health.sh`
  - add Codex/Claude CLI distribution fixture

Verification:

- `bash tests/test_codex_runtime.sh`
- `bash tests/test_hook_health.sh`
- `bash scripts/ci/self-application/check-codex-wrapper-thin.sh`

### P3: Prompt-input Proof and Docs Cleanup

- a new optional prompt-input test under `tests/`
  - optional, skipped when `codex` is unavailable
  - uses temp HOME and `codex debug prompt-input`
  - asserts `vibeguard-start`, `Chat Contract`, and `Key Detailed Rules`
- `docs/openai-codex-best-practices.md`
  - keep as reference only; do not treat as VibeGuard runtime contract
- `docs/internal/plans/agent-rules-distribution.md`
  - update status as steps land

Verification:

- the optional prompt-input test created in P3
- `bash scripts/ci/validate-doc-paths.sh`

## Acceptance Criteria

The remediation is complete when all of the following are true:

- `setup.sh --check` reports Codex health using semantic checks and exact native capability language.
- A healthy Codex install does not show red drift solely because unrelated `config.toml` fields changed.
- `~/.codex/AGENTS.md` managed block is validated for start/end marker integrity.
- Marker-external AGENTS content is visible in status output.
- Global Codex AGENTS content contains only cross-repo valid rules.
- VibeGuard repo-specific constraints live in repo-level `AGENTS.md`.
- Wrapper failure paths can be diagnosed without changing normal Codex stdout.
- Codex contract tests run from one command and pass in the current session.

## Validation Matrix

| Scenario | Input | Expected output | Verify command |
|---|---|---|---|
| Healthy Codex install | current machine with managed hooks and AGENTS | semantic OK, exact capability list | `bash setup.sh --check` |
| 0-byte AGENTS | temp HOME with empty `.codex/AGENTS.md` | BROKEN | `bash tests/test_setup.sh` |
| marker-external AGENTS text | managed block plus extra non-empty line | WARN, not silent OK | `bash tests/test_setup.sh` |
| missing adapter | wrapper with missing `hooks/_lib/codex_adapter.sh` | diagnostic event/log | `bash tests/test_codex_runtime.sh` |
| PreToolUse hook failure | wrapped hook exits nonzero | `permissionDecision=deny` | `bash tests/test_codex_runtime.sh` |
| native PostToolUse Bash payload | Bash output payload without `file_path` | documented behavior, no false claim | `bash tests/test_codex_runtime.sh` |
| hook-health mixed CLIs | fixture with codex and claude rows | CLI distribution counts both | `bash tests/test_hook_health.sh` |
| prompt-input visibility | temp HOME with injected AGENTS | prompt input contains VibeGuard anchors | optional P3 prompt-input test |

## Rollout Plan

1. Land P0 in one PR because it fixes user-facing truth and global-context safety.
2. Land P1 in a second PR because it changes status/check semantics for shared files.
3. Land P2 in a third PR because wrapper diagnostics touch runtime behavior.
4. Keep P3 optional if `codex debug prompt-input` is unstable across Codex versions; if skipped, document the skip condition in test output.

Each PR must include:

- changed file list
- before/after command output for the relevant status command
- test commands run in that PR
- any remaining Evidence gaps

## Risk Register

| Risk | Impact | Mitigation |
|---|---|---|
| AGENTS cleanup removes user notes | High | only report marker-external content by default; require confirmation for cleanup |
| status command becomes too noisy | Medium | group output into OK/WARN/BROKEN and keep exact repair command |
| whole-file drift still causes confusion | Medium | downgrade checksum-only drift to INFO when semantic checks pass |
| Codex CLI changes prompt debug output | Medium | make prompt-input test optional and version-gated |
| wrapper diagnostics leak command content | Medium | reuse existing redaction helpers or cap detail length |

## Handoff

```yaml
handoff:
  mode: plan_first
  artifacts:
    - docs/internal/plans/agent-rules-distribution.md
  verification_owner: main agent
  stop_conditions:
    - Codex native hook support expands beyond Bash/Stop and invalidates the capability contract
    - setup/check changes would delete user-managed AGENTS content without confirmation
    - tests require real model calls instead of local CLI/debug surfaces
  lane_map:
    codex_rules_distribution: main agent
    setup_status_semantics: main agent
    wrapper_diagnostics: main agent
    codex_contract_tests: main agent
```

## Open Evidence Gaps

- Need a current-session `codex debug prompt-input` proof before claiming Codex prompt visibility beyond file presence.
- Need a real native Bash `PostToolUse` payload sample from Codex logs or controlled hook fixture before changing `post-build-check` behavior.
- Need to decide whether the status command is `setup.sh --codex-status`, `setup.sh --check --codex`, or a standalone script under `scripts/`.
