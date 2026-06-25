# Spec: Make Learn a first-class signal inbox

- Status: Draft
- Date: 2026-06-25
- Owner: @majiayu000
- Readiness: plan_first
- Severity: P0
- Related: `scripts/gc/learn_digest.py`, `hooks/skills-loader.sh`, `hooks/learn-evaluator.sh`, `scripts/gc/gc-scheduled.sh`, `schemas/command-learn-output.schema.json`, `.claude/commands/vibeguard/learn.md`, `docs/how/learning-skill-generation.md`

## Issue Tracking

- Umbrella: https://github.com/majiayu000/vibeguard/issues/526
- Bounded current-project preview: https://github.com/majiayu000/vibeguard/issues/527
- Signal schema and classification: https://github.com/majiayu000/vibeguard/issues/528
- Read-only display and triage state: https://github.com/majiayu000/vibeguard/issues/529
- Adoption compiler and verification: https://github.com/majiayu000/vibeguard/issues/530
- Success trajectory learning: https://github.com/majiayu000/vibeguard/issues/531

## Implementation notes

- `scripts/learn/adoption.py` materializes adopted signals into append-only
  records with verification commands, baseline, expected later observation, and
  rollback path.
- `scripts/learn/adoption.py verify` requires fresh evidence newer than the
  adoption record before marking a signal `verified` or `regressed`.
- `scripts/learn/trajectory.py` records W-37 success and failure trajectories
  separately and rejects success-only retrieval when failure lessons exist for
  the same task class.

## 1. Problem

The public learning story says VibeGuard should turn repeated mistakes into
reusable defenses. The current execution path only implements the first part of
that loop:

1. hooks append events and session metrics;
2. scheduled GC aggregates threshold-based signals into `learn-digest.jsonl`;
3. `/vibeguard:learn` is a prompt that asks the model to interpret those rows.

That makes Learn a rough digest, not a product surface. It can surface useful
signals, but it cannot yet prove those signals are correctly attributed, manage
triage state, materialize an adopted improvement, or evaluate whether a learned
change reduced recurrence.

The immediate risk is not missing a learning opportunity. The immediate risk is
learning from untrusted or misattributed signals and turning noisy data into
global rules, hooks, or skills.

## 2. Verified facts

Verified against the local repository and live GitHub state on 2026-06-25:

- `scripts/gc/learn_digest.py` iterates every project under
  `$VIBEGUARD_LOG_DIR/projects` and appends matching entries to
  `learn-digest.jsonl`.
- Re-running `learn_digest.py` appends another row for the same project/window;
  there is no stable signal fingerprint, upsert, or triage state.
- `sessions` on `repeated_warn`, `chronic_block`, and `hot_files` is currently
  the count of all sessions seen in the project window, not the count of
  sessions affected by that specific signal.
- `slow_sessions` counts events with `duration_ms > 5000`; it is not a count of
  slow sessions.
- `warn_escalation` compares early and late raw warn totals without
  normalizing for event volume or session count.
- `hot_files` derives a path with `evt["detail"].split()[-1]`, so free-text
  details and external temp paths can be attributed to the current project.
- `hooks/skills-loader.sh` reads all rows after `.learn-watermark`, displays
  only the first five signals, then advances the watermark to the latest digest
  timestamp. Signals beyond the first five are effectively hidden from later
  display.
- `schemas/command-learn-output.schema.json` models a defensive Mode A report
  with `error`, `rootCause`, `improvements`, and two boolean verification fields.
  It does not model preview, triage, skill extraction, runtime fixes, scoped
  suppressions, or outcome evaluation.
- PR #515 is merged and provides false-positive metadata plus
  `scoped_suppressions` validation. Learn should reuse that governance path for
  false-positive and over-blocking signals.
- PR #235 is merged and adds W-37: agent learning memory must draw from
  successful and failed trajectories. The current Learn pipeline is still
  failure/friction oriented.
- `tests/test_gc_scheduled.sh` covers scheduled GC orchestration,
  malformed UTF-8 tolerance, stale-project code-scan avoidance, and catch-up
  behavior. It does not cover Learn product semantics such as scoped preview,
  path ownership, stable IDs, read-only display, triage state, or adopt/verify.

## 3. Product definition

Learn should be three cooperating surfaces:

```text
Learn = Signal Inbox + Adoption Compiler + Outcome Evaluator
```

- Signal Inbox: deterministic analysis turns logs and code-scan observations
  into trusted, bounded, deduplicated signals with stable IDs and evidence.
- Adoption Compiler: a human adopts a signal into the smallest appropriate
  action: runtime fix, config tuning, guard change, scoped suppression, project
  code change, or skill draft.
- Outcome Evaluator: later observations verify whether the adopted action
  reduced recurrence without increasing false positives or regressions.

The model may explain and propose actions. It must not be responsible for raw
JSONL parsing, project scoping, event counting, fingerprinting, or state
mutation.

## 4. Goals

- G1: `/vibeguard:learn` defaults to a fast, read-only, current-project preview.
- G2: Learn signal evidence is trustworthy enough to triage. Counts, affected
  sessions, paths, project ownership, and time windows must be explicit.
- G3: Re-running the same analysis over the same evidence is idempotent. It
  should update observations for a stable signal, not create duplicate problems.
- G4: Displaying signals is read-only. Only explicit commands such as adopt,
  skip, or snooze change state.
- G5: Signal classification controls the action space. Runtime-health signals
  do not suggest guard creation; false positives reuse scoped suppression; noise
  is collected or ignored.
- G6: Adopted changes carry verification commands and can later become verified
  or regressed based on fresh evidence.
- G7: Scheduled global GC remains available, but it becomes a batch producer of
  candidate observations rather than the interactive Learn entrypoint.

## 5. Non-goals

- Rewriting the entire pipeline in Rust in the first tranche.
- Adding a daemon, embedding clustering, or automatic rule mutation.
- Automatically applying learned changes without human adoption.
- Automatically closing GitHub issues from Learn state.
- Replacing `gc-scheduled.sh`; it should call the new analyzer once the analyzer
  is ready.
- Changing unrelated guard semantics while building the Learn substrate.

## 6. Command model

### 6.1 Interactive default

```bash
/vibeguard:learn
```

Default semantics:

- scope: current Git repository;
- mutation: none;
- output: deterministic preview plus human explanation;
- code scan: off by default;
- budget: bounded by event count, byte count, and elapsed time;
- result: return `partial: true` with `truncated_reason` when a budget is hit.

Recommended deterministic entrypoint:

```bash
python3 scripts/learn/analyze.py \
  --scope current \
  --project-root "$PWD" \
  --dry-run \
  --no-code-scan \
  --budget-ms 2000 \
  --format json
```

### 6.2 Batch producer

```bash
python3 scripts/learn/analyze.py \
  --scope global \
  --scheduled \
  --max-projects 500 \
  --budget-ms 60000 \
  --output "$HOME/.vibeguard/learn-digest.jsonl"
```

Scheduled GC may call this path. If the global budget is exhausted, it must
write a partial status instead of running indefinitely.

### 6.3 Triage commands

```text
/vibeguard:learn show <signal-id>
/vibeguard:learn adopt <signal-id>
/vibeguard:learn skip <signal-id> --reason "..."
/vibeguard:learn snooze <signal-id> --days 14
/vibeguard:learn verify <signal-id>
```

Display commands are read-only. State changes require an explicit triage
command and append a transition record.

## 7. Data model

### 7.1 Signal identity

Do not include the observation window in the stable signal ID.

```text
signal_id = hash(schema_version, project_hash, type, normalized_key)
observation_id = hash(signal_id, window_start, window_end)
```

This lets the same long-lived issue recur across windows while preserving each
observation window as evidence.

### 7.2 Signal fields

Each signal must include:

```json
{
  "schema_version": 1,
  "signal_id": "lrn_...",
  "project_hash": "dc1db069",
  "project_root": "/abs/project",
  "type": "hot_files",
  "classification": "noise",
  "normalized_key": "path:/abs/file.rs",
  "path": "/abs/file.rs",
  "path_relation": "in_project",
  "source_hook": "post-edit-guard",
  "source_tool": "Edit",
  "affected_sessions": 3,
  "occurrences": 31,
  "first_seen": "2026-06-24T00:00:00Z",
  "last_seen": "2026-06-24T12:00:00Z",
  "event_rate": 0.11,
  "evidence_samples": []
}
```

Required path relations:

- `in_project`
- `external`
- `unknown`

Only `in_project` paths can become `project_quality` or `hot_files` signals for
the current repo. External paths may be retained as diagnostics, but they must
not be attributed to the current project.

### 7.3 Classifications

| Classification | Meaning | Allowed first actions |
|---|---|---|
| `runtime_health` | VibeGuard's own metrics, logging, storage, or config behavior is unhealthy | `fix_runtime`, `tune_config`, `collect_more_evidence` |
| `defense_gap` | A mistake should have been detected but was missed | `enhance_guard`, `add_hook`, `add_rule` |
| `defense_friction` | A guard/hook is noisy, over-blocking, or false-positive prone | `add_scoped_suppression`, `enhance_guard`, `tune_config` |
| `project_quality` | The target project has a repeated code or structure issue | `change_project_code`, `collect_more_evidence` |
| `workflow_friction` | The agent or workflow repeatedly stalls, retries, or times out | `create_or_update_skill`, `tune_config`, `collect_more_evidence` |
| `skill_candidate` | A verified, non-obvious, reusable discovery should be retained | `create_or_update_skill` |
| `noise` | Evidence is external, malformed, biased, or insufficient | `no_action`, `collect_more_evidence` |

### 7.4 Recommended actions

Recommended action types:

- `fix_runtime`
- `tune_config`
- `enhance_guard`
- `add_hook`
- `add_rule`
- `add_scoped_suppression`
- `change_project_code`
- `create_or_update_skill`
- `collect_more_evidence`
- `no_action`

The current `command-learn-output.schema.json` should become an envelope rather
than the whole product protocol.

## 8. State model

State must be append-only and auditable. The initial MVP states are:

- `new`
- `adopted`
- `skipped`
- `stale`

The schema should reserve:

- `snoozed`
- `verified`
- `regressed`

Transition records:

```json
{
  "signal_id": "lrn_a31f...",
  "from": "new",
  "to": "adopted",
  "reason": "add scoped suppression",
  "ts": "2026-06-25T00:00:00Z"
}
```

`hooks/skills-loader.sh` must not advance triage state just because it displayed
a signal. Loader output should be read-only.

## 9. Adoption and verification loop

Adoption is complete only when it records:

- the selected action type;
- changed files or generated artifact;
- original evidence samples;
- targeted verification command;
- regression command or CI check;
- baseline before the change;
- expected later observation change;
- rollback path.

A signal becomes `verified` only after a later observation window or a targeted
reproduction confirms that the recurrence fell and no new false-positive or
regression signal appeared.

## 10. Required first issue breakdown

### Issue A: Bounded current-project preview

Add the deterministic analyzer entrypoint and default current-project preview.

Acceptance criteria:

- current-project preview is read-only and does not write digest or watermark;
- supports `--scope current|global`, `--project-root`, `--project-hash`,
  `--dry-run`, `--format json|text`, `--output`, `--max-projects`,
  `--max-events`, `--budget-ms`, `--guard-timeout`, and `--no-code-scan`;
- returns `partial: true` with `truncated_reason` when a budget is reached;
- external paths do not become current-project hot-file signals;
- affected session counts are per signal;
- repeated runs over the same fixture produce the same signal IDs;
- tests cover current-project scope, external-path attribution, per-signal
  affected sessions, and budget truncation.

### Issue B: Signal schema and classification

Add a future learn signal schema at schemas/learn-signal.schema.json and
update Learn command schema to model preview/adopt/verify/extract-skill
envelopes.

Acceptance criteria:

- signal schema validates `signal_id`, `observation_id`, classification,
  path relation, affected sessions, evidence samples, and recommended actions;
- `command-learn-output.schema.json` supports at least `preview`, `adopt`,
  `verify`, and `extract_skill` modes;
- runtime-health truncation signals cannot recommend guard/rule creation;
- external paths classify as `noise` or diagnostics, not `project_quality`;
- schema tests are added to the existing workflow contract checks.

### Issue C: Read-only display and explicit triage state

Replace watermark-as-consumption with explicit state transitions.

Acceptance criteria:

- loader display does not mutate signal state;
- showing only the first N signals cannot hide or consume the remaining signals;
- state transitions are append-only and support `adopt`, `skip`, and `snooze`;
- state is keyed by stable `signal_id`, not digest timestamp;
- tests prove display is read-only and repeated display is stable.

### Issue D: Adoption compiler and verification

Connect adopted signals to minimal artifacts and verification commands.

Acceptance criteria:

- each classification maps to a constrained action space;
- `defense_friction` can propose `scoped_suppressions` using the existing
  false-positive governance model from PR #515;
- adopted runtime-health signals produce runtime/config work, not guard/rule
  work;
- adopted signals store verification commands and baseline evidence;
- verification can mark a signal as `verified` or `regressed`;
- tests cover at least one runtime-health adoption, one scoped-suppression
  adoption, and one no-action/noise path.

### Issue E: Success trajectory learning

Add W-37-compliant success trajectory intake after the failure/friction path is
trusted.

Acceptance criteria:

- successful low-friction trajectories are recorded with explicit outcome
  flags;
- retrieval or preview can show success and failure evidence for a similar
  task class;
- success evidence cannot overwrite or hide failure evidence;
- tests prove success-only retrieval is rejected when failure lessons exist for
  the same task class.

## 11. Execution order

1. Spec and issue creation.
2. Issue A: bounded current-project preview.
3. Issue B: signal schema and classification.
4. Issue C: explicit triage state and read-only loader display.
5. Issue D: adoption compiler and verification.
6. Issue E: success trajectory learning.

Issue A must land before B-D because the remaining work depends on trusted
signal IDs and scoped analysis. Issue E is P1 after the failure/friction path is
credible.

## 12. Validation

Focused checks:

```bash
python3 -m py_compile scripts/learn/analyze.py scripts/gc/learn_digest.py
bash tests/test_gc_scheduled.sh
bash tests/test_workflow_contracts.sh
bash scripts/ci/validate-doc-paths.sh
bash scripts/ci/validate-doc-command-paths.sh
```

Behavioral checks:

- current-project preview on representative logs completes within the configured
  budget and returns partial status rather than hanging;
- display paths do not mutate triage state;
- repeated fixture analysis produces stable IDs;
- external paths are not attributed to the current project.

Before submission for implementation PRs, run the focused tests plus any schema
or command tests added by that PR. Full release gates remain unchanged.

## 13. Handoff

```yaml
handoff:
  mode: execute_direct
  artifacts:
    - docs/specs/learn-first-class-signal-inbox.md
  runtime_pinning_snapshot: null
  verification_owner: root orchestrator
  stop_conditions:
    - open PR has unresolved GraphQL review threads
    - CI/check rollup is not fresh for current head
    - analyzer output mutates digest or triage state during preview
    - external path is attributed as current-project quality
    - repeated analysis over the same fixture changes signal_id
  lane_map:
    issue-a-preview: implementation worker
    issue-b-schema: implementation worker after issue-a-preview
    issue-c-triage-state: implementation worker after issue-b-schema
    issue-d-adoption-verify: implementation worker after issue-c-triage-state
    issue-e-success-trajectory: follow-up worker
    merge-review: independent reviewer
```

## 14. Open questions

- Should the analyzer live under `scripts/learn/` immediately, or should
  `scripts/gc/learn_digest.py` become a thin compatibility wrapper first?
- Should triage state live under `$VIBEGUARD_LOG_DIR/learn-state.jsonl` or under
  project-specific state directories?
- Should global scheduled scans default to no code scan and rely on explicit
  `--code-scan` until code-scan budgets are proven?
- Which command should own `adopt`: a deterministic script, a slash-command
  prompt, or a two-step script-plus-prompt flow?
