window.BENCHMARK_DATA = {
  "lastUpdate": 1780262339117,
  "repoUrl": "https://github.com/majiayu000/vibeguard",
  "entries": {
    "Hook Latency (P95)": [
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "VibeGuard Agent",
            "username": "majiayu000"
          },
          "committer": {
            "email": "1835304752@qq.com",
            "name": "VibeGuard Agent",
            "username": "majiayu000"
          },
          "distinct": true,
          "id": "9c7864761f00183791ffb099d49fa0d96f387fbb",
          "message": "ci: enable gh-pages fetch for benchmark action\n\ngh-pages branch was created today (commit dd63870), so the benchmark\naction should fetch it instead of assuming first-run semantics.\nKeeping skip-fetch=true after the branch exists makes git switch fail\nwith \"invalid reference: gh-pages\" because the checkout step only\nfetches main.\n\nConstraint: benchmark-action/github-action-benchmark@v1 does git switch\n against local refs; default actions/checkout is single-branch\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nTested: identified root cause from CI failure logs on run 24520946487\nNot-tested: post-push CI green status (will verify after push)",
          "timestamp": "2026-04-17T00:29:40+08:00",
          "tree_id": "ebd22764752a0f872d30f2632fcc6a0cc94e568c",
          "url": "https://github.com/majiayu000/vibeguard/commit/9c7864761f00183791ffb099d49fa0d96f387fbb"
        },
        "date": 1776357217968,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 176,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 213,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 232,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 119,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 118,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 165,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 117,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 44,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 44,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "17504d069ffa1d46da8a02f02a4bcda1fbf2226c",
          "message": "chore: housekeeping — README trim, CI Node 24 opt-in, pending hook/rule work (#75)\n\n* docs: drop vs-Everything-Claude-Code blurb from README\n\nUser feedback: the comparison table read like promotional positioning;\nREADME should describe what the tool does, not how it relates to\nadjacent projects.\n\nScope-risk: narrow\nReversibility: clean\n\n* ci: opt in to Node 24 runtime for JS actions\n\nSilences the deprecation warnings that appear on every CI run by setting\nFORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true at the workflow level. This is\nGitHub's officially documented opt-in until all third-party actions\npublish Node 24–compatible releases (hard cutover on 2026-09-16).\n\nConstraint: benchmark-action/github-action-benchmark@v1 has no Node 24\n release yet, so bumping the action version is not an option today;\n the env var is the supported bridge until they ship.\nRejected: bump actions/checkout/setup-node/setup-python major versions\n (partial fix; still leaves third-party actions on Node 20)\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nTested: env var name and value verified against GitHub's CI annotation\nNot-tested: green CI run (will observe on next push)\n\n* feat(hooks): tag session/event log with originating CLI\n\nSession inference walks the process tree for a Claude Code or Codex\nancestor and records the result in VIBEGUARD_CLI. The CLI tag is\npropagated through vg_log() into every JSONL event, and stats.sh /\nhook-health.sh get a new \"CLI distribution\" section so mixed-agent\nprojects can tell Claude and Codex traffic apart.\n\nChanges:\n- hooks/log.sh: detect codex vs claude via ps comm + args; scope\n  session file name per CLI so parallel instances do not collide\n- hooks/run-hook-codex.sh: export VIBEGUARD_CLI=codex so the wrapper\n  path short-circuits the tree walk\n- scripts/stats.sh: add by_cli Counter + printout\n- scripts/hook-health.sh: add CLI distribution and per-event cli field\n\nScope-risk: narrow (log schema is additive: existing consumers ignore\n the new field; old events without cli are shown as \"unknown\")\nReversibility: clean\nTested: schema is additive; existing by_decision/by_hook counters\n unchanged\nNot-tested: end-to-end verification from a Codex session\n\n* feat(hooks): detect W-15 consecutive same-file edit loop\n\npost-edit-guard now counts consecutive Edit events targeting the same\nfile with no intervening edits elsewhere. Three in a row triggers a\n[W-15] warn — distinct from the existing CHURN counter, which sums\nnon-consecutive session edits and can mask a tight toggle-loop.\n\nAlso:\n- hooks/CLAUDE.md: document the new W-15 signal in the post-edit-guard\n  capability row\n- .claude/commands/vibeguard/exec-plan.md: when ExecPlan accumulates\n  ≥5 Surprises, suggest re-running /vibeguard:interview (decayed\n  assumption tree — W-02 / W-15 rationale); suggestion only, never\n  an enforced halt\n\nConstraint: W-15 spec calls for \"±10 lines\" region matching, but the\n event log stores file paths only; this is a file-level proxy, noted\n inline in the hook\nScope-risk: narrow (adds a single warn branch; pass path unchanged)\nReversibility: clean\nTested: logic reviewed against log schema; no regression in existing\n CHURN counter\nNot-tested: live session that crosses the 3-consecutive threshold\n\n* docs(rules): add W-17 / U-32 / SEC-12 from knowledge scout findings\n\nThree rules sourced from 2026-04-16 research across Addy Osmani,\nAnthropic, Martin Fowler, and Simon Willison.\n\n- W-17 (workflow.md): before adding a new gate, must first check\n  whether the target is covered by an existing one. Curse of\n  instructions: 10 gates score worse than 5. Complements U-32 which\n  sets the overload threshold after the fact.\n- U-32 (coding-style.md): active rules per file capped at ~30;\n  absolute language (\"must / never\") must be paired with a\n  degradation path so rules do not become illusion-of-control.\n- SEC-12 (security.md): treat MCP tool descriptions as LLM-bound\n  instructions. Requires hash audit + diff gate to defend against\n  Rug Pulls / Tool Poisoning / Cross-Server Shadowing / Unescaped\n  String Injection.\n\nAll three follow the project's existing rule format (rationale +\nsources + mechanical checks) and reference W-15 where applicable.\n\nScope-risk: moderate (rules bias agent behavior; additive only)\nReversibility: clean (delete sections to revert)\nTested: format matches surrounding rules; cross-references verified\nNot-tested: observed agent behavior change (requires rollout)\n\n* docs: add 2026-04-16 / 2026-04-17 knowledge-discovery notes\n\n- 2026-04-16.md: RSS scout distillation of 31 long-form pieces ≥20 pts;\n  traces the provenance of W-17 / U-32 / SEC-12 (committed separately).\n- 2026-04-17-vibeguard-self-audit.md: internal audit of VibeGuard vs\n  Fowler's MDD-failure warning and Bridge 5 sensor-coverage checklist.\n\nThese notes are the evidence trail for the rule and hook changes that\nlanded in this branch. Keeping them in-tree so future rule edits can\ncite concrete sources rather than rebuilding the reasoning.\n\nScope-risk: narrow (docs only)\nReversibility: clean\n\n* perf(hooks): skip ps(1) args call unless comm is node\n\nBenchmark (PR #75) flagged a 2.2–4.3× P95 regression across every hook,\nincluding stop-guard and learn-evaluator which this branch did not\ntouch. Root cause: the CLI detection walk now forks ps twice per\nancestor level (comm and args), and the walk runs up to 8 levels per\nhook cold-start.\n\nFix: branch on comm first. The fast-path case covers claude-code,\ncodex-cli, Electron, and login-shell/launchd/init ancestors without\nthe second fork. Only when comm == node (the shared binary for every\nAnthropic / OpenAI Node CLI) do we run ps -o args= to disambiguate.\n\nExpected impact on the benchmark suite:\n- stop-guard / learn-evaluator: walk-dominant, should return near\n  the previous 44ms baseline\n- post-write-guard: no per-hook work beyond the session detect, same\n- post-edit-guard: still has the new W-15 python3 scan; expect\n  partial recovery (~1.5×), which is below the alert threshold\n\nConstraint: benchmark threshold is 1.50× on a 150ms-scale budget, so\n shaving 7 forks × ~15ms each is the dominant lever\nRejected: single combined `ps -o comm=,args=` (field split relies on\n whitespace and is BSD/GNU-inconsistent) | vg-helper extension for\n W-15 scan (wider scope; revisit if post-edit-guard still alerts)\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nTested: logic reviewed for break semantics (case is not a loop, so\n `break` inside case exits the enclosing while as documented in\n POSIX); flattened nested case into case+if to keep the break target\n unambiguous\nNot-tested: live benchmark run (will observe on next push)",
          "timestamp": "2026-04-17T00:55:02+08:00",
          "tree_id": "a746eea2a229fe3a22ec17c2beaaf99bcfc1648b",
          "url": "https://github.com/majiayu000/vibeguard/commit/17504d069ffa1d46da8a02f02a4bcda1fbf2226c"
        },
        "date": 1776358745027,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 177,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 209,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 232,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 276,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 282,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 204,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 130,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 131,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "6b29d4a506b77390604d502028a0de93f98566de",
          "message": "test(vg-helper): add unit tests for session_metrics time-window and session filters (#76)\n\n* test(vg-helper): add unit tests for parse_iso_ts and session/time-window filters\n\nAdds 11 unit tests covering:\n- parse_iso_ts: epoch, Z suffix, +00:00 suffix, HMS parsing, invalid input\n- 30-minute time-window filter: inside/outside/boundary cutoff logic\n- Session ID filter: same session kept, different session excluded, missing session field passes\n\nCloses #67.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(session-metrics): fix month bounds panic, malformed-ts filter bypass, and tautology test\n\n- parse_iso_ts: validate month in [1,12] before indexing month_days to\n  prevent panic on corrupt timestamps like 2024-13-01T00:00:00Z\n- extract event_passes_time_filter helper: events whose `ts` is present\n  but unparseable are now excluded (were silently falling through to\n  events.push, bypassing the 30-minute window entirely)\n- replace tautology `assert!(cutoff >= cutoff)` with a real boundary\n  assertion that catches regressions from < to <=\n- add test_parse_out_of_range_month_returns_none (issue 2)\n- add test_malformed_ts_is_excluded_by_filter (issue 1 caller path)\n- add test_no_ts_field_passes_filter and test_recent_ts_passes_filter\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(session-metrics): reject invalid day/time values and non-string ts fields\n\nparse_iso_ts now validates day (1–max_days_in_month including leap years),\nhour (0–23), minute (0–59), and second (0–59), rejecting timestamps like\n2026-04-00T99:99:99Z or 2026-02-31T12:00:00Z instead of computing bogus\nepoch values.\n\nevent_passes_time_filter now uses a match on the raw JSON Value so that ts\nfields typed as number, object, array, or null are excluded (false) rather\nthan falling into the previous else { true } branch that admitted them as\nif no ts field existed.\n\nNew tests cover: invalid day ranges, leap-year boundary, invalid time\ncomponents, and non-string ts variants (numeric, object, array, null).\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(session-metrics): address review comments — negative ts bounds, session/time tests via production path\n\n- parse_iso_ts: reject negative hour/min/sec (lower-bound guard was missing)\n- extract event_passes_session_filter helper; use it in run() and tests\n- rewrite 30-min window tests to call event_passes_time_filter with deterministic inputs\n- rewrite session filter tests to call event_passes_session_filter instead of re-deriving inline\n- add negative time-component cases to test_parse_out_of_range_time_returns_none\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* test(session-metrics): add run() integration tests via injectable run_inner\n\nExtract run() body into run_inner(args, stdin: impl BufRead, out: &mut impl Write, cutoff_secs)\nso tests can drive the full production path without spawning a process. Add 5 tests covering:\nskip-hook filtering before event-count check, session filter before event-count check,\ntime-window filter before event-count check, LEARN_SUGGESTED signal output + metrics file append,\nand clean-session (no-signal) path.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-19T00:40:37+08:00",
          "tree_id": "6aaddaabb81b723c3b8f92a1a341c44dc0d2a93c",
          "url": "https://github.com/majiayu000/vibeguard/commit/6b29d4a506b77390604d502028a0de93f98566de"
        },
        "date": 1776530678706,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 203,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 236,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 259,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 303,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 220,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 317,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 227,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 142,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 141,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "1d6b04d149bc977b887e376d3a8f21c6cc996bad",
          "message": "Harden observability against malformed event logs (#77)\n\n* Harden observability against malformed event logs\n\nEvent-log consumers had duplicated JSONL parsing paths and crashed when the\nshared ~/.vibeguard/events.jsonl file contained truncated multibyte content.\nThis centralizes tolerant event parsing in a shared helper, reuses it across\nruntime consumers, and makes vg_log truncate detail on UTF-8 boundaries so the\nwriter and readers fail less asymmetrically.\n\nConstraint: Event logs are written from shell hooks and may contain truncated multibyte text from byte-oriented slicing\nRejected: Patch hook-health/stats only | leaves other consumers vulnerable and preserves parsing duplication\nConfidence: high\nScope-risk: moderate\nReversibility: clean\nDirective: New event-log consumers should import hooks/_lib/event_log.py instead of open()+json.loads() loops\nTested: bash tests/test_hooks.sh; bash tests/test_hook_health.sh; bash tests/test_stats.sh; bash tests/test_quality_grader.sh; bash scripts/hook-health.sh 24; bash scripts/stats.sh 7; bash scripts/quality-grader.sh 7 --json\nNot-tested: GC/archival readers in scripts/gc/ still use separate parsing paths\n\n* fix: address review comments and resolve issue #79 false-positive\n\n- P1 (event_log.py): parse_ts now ensures timezone-aware datetimes by\n  replacing missing tzinfo with UTC, preventing TypeError when comparing\n  naive timestamps against timezone-aware `since` values\n\n- P2 (log.sh): Python UTF-8 truncation fallback in vg_truncate_utf8 used\n  `python3 - <<'PY'` + a pipe, which caused the heredoc to consume stdin\n  instead of the piped text; replaced with `python3 -c '...'` so stdin\n  is free for the pipe\n\n- Issue #79 (rust guards): STAGED_RS pipeline under set -euo pipefail\n  aborted the script when no .rs files were staged because the first grep\n  exited 1 and pipefail propagated before `|| true` could catch it;\n  all three affected files (check_unwrap_in_prod.sh, check_nested_locks.sh,\n  common.sh) now guard with a preflight `grep -q` check or a trailing\n  `|| true` on the full pipeline\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(vg-helper): decode malformed UTF-8 with lossy replacement instead of aborting\n\nsession_metrics.rs: `line?` would propagate io::Error on non-UTF-8 stdin\nand abort the entire session-metrics command, silently disabling\nLEARN_SUGGESTED generation on the malformed-log path PR #77 hardened.\nChanged to `match line { Ok(l) => l, Err(_) => continue }`.\n\nlog_query.rs: `lines()` + `Err(_) => continue` silently dropped any line\nwith invalid UTF-8, causing churn/build-fail/paralysis/warn counters to\nundercount and escalation to fail to trigger in production.  Switched to\n`BufReader::read_until` + `String::from_utf8_lossy` so malformed bytes\nbecome U+FFFD rather than discarding the recoverable JSONL event.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(session-metrics): apply lossy UTF-8 read and bounded memory load\n\nsession_metrics.rs: replace stdin.lock().lines() with BufReader::read_until\n+ from_utf8_lossy so malformed UTF-8 bytes surface as U+FFFD rather than\nsilently dropping the entire event (mirrors the log_query.rs fix).\n\nsession_metrics.py: pass since=cutoff to load_events_from_file so the\n30-minute time filter runs during file reading rather than after full\nmaterialization; prevents O(full-log) memory/latency on large repos.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-19T00:50:10+08:00",
          "tree_id": "1f07e4207e9785b9a5f9f5831a3346eda47acda0",
          "url": "https://github.com/majiayu000/vibeguard/commit/1d6b04d149bc977b887e376d3a8f21c6cc996bad"
        },
        "date": 1776531256550,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 200,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 241,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 266,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 332,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 233,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 332,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 218,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 136,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 136,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "95b4caddc76d1ea8d23a6b5fde1366f5e6ba6149",
          "message": "feat: shift stable contract checks left into local pre-commit gate (#82)\n\n* feat: shift stable contract checks left into local pre-commit gate\n\nAdd a wrapper script that runs the deterministic, repository-local subset\nof CI contract checks locally, and a one-command installer that wires it\nas a git pre-commit hook. Update CONTRIBUTING.md with a Local Contract Gate\nsubsection documenting the local-vs-CI split table and the --quick flag.\nAdd a brief entrypoint note in README.md under Project Bootstrap.\n\nContract tests from PR #80 (test_manifest_contract.sh, test_eval_contract.sh)\nare guarded by file-existence checks so they activate automatically once that\nPR merges, with no changes needed here.\n\nConstraint: local gate must stay Unix-first; Windows contributors use CI\nRejected: duplicating check lists across hook configs | single wrapper is easier to maintain\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nTested: bash scripts/local-contract-check.sh --quick; validate-doc-paths.sh; validate-doc-command-paths.sh\nNot-tested: Windows Git Bash behavior\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(local-contract-gate): address four reviewer-found regressions\n\n- local-contract-check.sh: separate script path from extra args in\n  run_check() so doc-freshness --strict is no longer silently skipped\n  due to the path+args string failing the -f file-existence test\n- install-pre-commit-hook.sh: use `git rev-parse --git-path hooks`\n  instead of the hardcoded $REPO_ROOT/.git/hooks path, which breaks\n  in git worktree and submodule layouts\n- install-pre-commit-hook.sh: chain to an existing pre-commit hook\n  rather than overwriting it; installer is now idempotent (re-run\n  detects gate already present and exits 0)\n- tests/test_local_contract_gate.sh: add 11 tests covering the three\n  script behaviours above plus static analysis of installer output\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(local-contract-gate): resolve symlink-mutation, exec-chain, and dead-test regressions\n\n- install-pre-commit-hook.sh: break any symlink before writing so the\n  shared target (e.g. ~/.vibeguard/hooks/pre-commit-guard.sh) is never\n  mutated; save original content to pre-commit.vibeguard-prev and create\n  a wrapper that calls it with bash (not exec) so exec-terminated hooks\n  do not silently swallow the contract gate\n- test_local_contract_gate.sh: update chain assertions to match wrapper\n  approach; add symlink-safety test (shared target unchanged) and\n  exec-chain test (gate reachable via subprocess call)\n- ci.yml: wire tests/test_local_contract_gate.sh into the CI matrix so\n  these regressions are caught on every push\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(local-contract-gate): propagate original hook exit code in chained wrapper\n\nWhen an existing hook was chained, the generated wrapper ran both the\noriginal hook and the contract gate but ignored the original hook's exit\nstatus. If the original hook failed and the gate passed, git commit would\nsucceed incorrectly.\n\nCapture _prev_exit and _gate_exit separately; exit non-zero if either\nfails. Adds a test asserting the wrapper template contains both captures\nand the combined exit expression.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-19T03:07:46+08:00",
          "tree_id": "78ff6bb877be4f48c71d6d70b2a95b0525fc0111",
          "url": "https://github.com/majiayu000/vibeguard/commit/95b4caddc76d1ea8d23a6b5fde1366f5e6ba6149"
        },
        "date": 1776539492939,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 175,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 207,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 229,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 307,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 218,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 313,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 126,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 126,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "5366f6f190a4dfc8c563e67636d65d6db4428597",
          "message": "Merge pull request #84 from majiayu000/codex/english-rules-clean-pr\n\nTranslate and harden the canonical rule surface",
          "timestamp": "2026-04-19T12:29:45+08:00",
          "tree_id": "b4000f6d9753c6d1776cd495c28da3f8ba41556a",
          "url": "https://github.com/majiayu000/vibeguard/commit/5366f6f190a4dfc8c563e67636d65d6db4428597"
        },
        "date": 1776573233396,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 179,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 214,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 234,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 299,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 208,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 312,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 208,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 131,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 130,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "f5d477afd5cc8dfb1df86028b905ed4034a17569",
          "message": "Merge pull request #78 from majiayu000/docs/scout-2026-04-17\n\ndocs: 2026-04-17 knowledge scout + W-16 rationalizations pilot",
          "timestamp": "2026-04-19T12:53:11+08:00",
          "tree_id": "c6e9984c216b487403cca4e1ed494fbb5e21d93b",
          "url": "https://github.com/majiayu000/vibeguard/commit/f5d477afd5cc8dfb1df86028b905ed4034a17569"
        },
        "date": 1776574630179,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 184,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 218,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 239,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 305,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 214,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 320,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 221,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 134,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 134,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "ab1273ee668c6c0bb1a081fc9c45a0d6894c5c5b",
          "message": "fix(guards): move || true outside $() to prevent pipefail propagation (#85)\n\n* fix(guards): move || true outside $() to prevent pipefail propagation\n\nWith set -euo pipefail, a failed grep inside a multi-segment pipe propagates\nits non-zero exit even when a downstream { grep || true; } guard is present.\nMove the guard outside command substitution as `|| VAR=\"\"` so the outer\nassignment is always safe.\n\nFixes #79\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(guards): preserve grep output on exit-2 errors in debug-code scan\n\nReplace `|| DEBUG_CODE=\"\"` with `|| true` outside `$()` so partial\nscan results from grep read errors (exit code 2) are retained in\nDEBUG_CODE instead of being discarded.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-19T14:02:05+08:00",
          "tree_id": "3fc78798fb3c5bafdeaab7b8ad56194339163ce2",
          "url": "https://github.com/majiayu000/vibeguard/commit/ab1273ee668c6c0bb1a081fc9c45a0d6894c5c5b"
        },
        "date": 1776578760064,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 182,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 209,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 233,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 297,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 207,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 306,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 131,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 130,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "590ddca7e95965040c4648fdfb75816050c36e47",
          "message": "Converge VibeGuard onto one explicit runtime and contract model (#80)\n\n* Converge VibeGuard onto one explicit runtime and contract model\n\nCodex runtime behavior, install/profile metadata, verification gates, and product-facing docs had drifted into separate sources of truth. This change collapses those seams by making post-turn hook feedback explicit, introducing a canonical manifest/helper layer for install and rule metadata, hardening CI around contract tests, and re-pointing docs/eval flows at repository-owned sources.\n\nConstraint: Keep existing user-visible hook semantics intact while removing silent fail-open paths\nConstraint: No new runtime dependencies; use structured helpers and existing shell/Python surfaces\nRejected: Patch only app-server feedback and leave install/schema/doc drift in place | would preserve the same structural split-brain\nRejected: Add another standalone metadata file beside install-modules.json | increases surface area instead of converging it\nConfidence: high\nScope-risk: broad\nReversibility: clean\nDirective: Treat schemas/install-modules.json as the canonical install/profile contract and update generated or descriptive surfaces from it, not vice versa\nTested: tests/test_manifest_contract.sh; tests/test_eval_contract.sh; tests/test_codex_runtime.sh; tests/test_setup.sh; tests/test_hook_health.sh; VIBEGUARD_TEST_UPDATED_INPUT=1 tests/test_hooks.sh; tests/test_precision_tracker.sh; tests/unit/run_all.sh; tests/test_rust_guards.sh; scripts/verify/doc-freshness-check.sh --strict; scripts/ci/validate-manifest-contract.sh; scripts/ci/validate-doc-paths.sh; scripts/ci/validate-doc-command-paths.sh; scripts/ci/validate-precision-thresholds.sh; scripts/benchmark.sh --mode=fast\nNot-tested: Full GitHub Actions execution on remote runners after push\n\n* Remove flaky uv bootstrap and force UTF-8 eval reads\n\nThe PR checks failed for two environment-specific reasons rather than product logic: Ubuntu relied on astral.sh install.sh for uv and hit a transient 504, while Windows eval dry-run used locale-default decoding and crashed on non-ASCII rule files.\n\nConstraint: Keep the existing CI intent and eval contract unchanged while removing platform and network fragility\nRejected: Retry the curl installer | still leaves CI dependent on an external bootstrap script and network edge failures\nRejected: Mark the Windows eval contract test optional | hides the encoding bug instead of fixing it\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Prefer repository/local toolchain installs and explicit UTF-8 file reads in cross-platform validation paths\nTested: python3 -m py_compile eval/run_eval.py; bash tests/test_eval_contract.sh\nNot-tested: Full remote GitHub Actions rerun after push\n\n* Normalize eval contract path assertions across platforms\n\nWindows Smoke still failed after the UTF-8 fix because the eval contract test compared repository paths using the host's native separator expectations. The implementation was correct; the assertion was not portable.\n\nConstraint: Keep the eval dry-run contract identical while making the test stable on both Windows and Unix runners\nRejected: Drop the Windows eval contract check | would hide a real cross-platform contract regression surface\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Normalize path strings before comparing cross-platform CLI output in contract tests\nTested: bash tests/test_eval_contract.sh\nNot-tested: Full Windows remote rerun after push\n\n* Close Codex runtime contract gaps found during review\n\nThe architecture convergence PR introduced stronger Codex runtime and\nmanifest helpers, but review identified four fail-open edges: normalized\nthread ids could collide, prefixed feature keys could be clobbered,\ninstalled-rule drift was hidden when the installed set was empty, and\nlegacy MCP cleanup helper failures were converted into green no-op paths.\n\nConstraint: Preserve the existing setup/runtime contract while making review-discovered failure modes observable\nRejected: Treat the comments as theoretical | each issue can corrupt session telemetry, user config, or install drift reporting\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Keep helper failures explicit; do not convert infrastructure errors into SKIP/green status paths\nTested: python3 -m py_compile scripts/codex/app_server_wrapper.py scripts/lib/codex_config_toml.py scripts/lib/vibeguard_manifest.py eval/run_eval.py; bash -n scripts/setup/targets/codex-home.sh scripts/verify/doc-freshness-check.sh; bash tests/test_codex_runtime.sh; bash tests/test_manifest_contract.sh; bash scripts/verify/doc-freshness-check.sh --strict; bash tests/test_eval_contract.sh; bash scripts/ci/validate-manifest-contract.sh; bash scripts/ci/validate-doc-paths.sh; bash scripts/ci/validate-doc-command-paths.sh; bash tests/test_setup.sh\nNot-tested: Remote GitHub Actions rerun after push\n\n* Keep doc freshness scoped to generated common-rule tables\n\nAfter the canonical rule docs became generated, docs/rule-reference.md now\ncontains language-specific rule IDs as well as common U/W/SEC rules. The\narchitecture convergence check should still compare only the documented\ncommon scope, otherwise generated language rows look like false drift.\n\nConstraint: #84 made docs/rule-reference.md a generated all-rule reference\nRejected: Remove language rules from generated docs | would undo the single-source rule reference improvement\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Filter reference-rule comparisons by the scope being validated, not by every ID present in the generated reference\nTested: bash scripts/verify/doc-freshness-check.sh --strict; bash scripts/ci/validate-generated-rule-docs.sh; bash scripts/ci/validate-manifest-contract.sh; bash tests/test_manifest_contract.sh; bash tests/test_eval_contract.sh\nNot-tested: Remote GitHub Actions rerun after force-push\n\n* Propagate codex_hooks enable failures during setup\n\nReview found that the codex_hooks feature helper still used the same\nfail-open pattern as the legacy MCP cleanup path: helper failures were\nconverted into an ERROR string and setup could continue to completion.\nReturn non-zero instead and cover the failure path in setup regression.\n\nConstraint: A completed setup must not leave Codex hooks disabled because a config helper failed\nRejected: Only print a red warning and continue | users would still get a broken runtime with a successful install exit\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Setup helper failures should abort install unless the helper explicitly returns SKIP\nTested: bash -n scripts/setup/targets/codex-home.sh tests/test_setup.sh; python3 -m py_compile scripts/lib/codex_config_toml.py; bash tests/test_setup.sh\nNot-tested: Remote GitHub Actions rerun after push\n\n* Handle commented TOML tables and TASTE rule references\n\nCodex review found two parser gaps: user-edited TOML tables with trailing\ncomments were not recognized as existing sections, and reference rule ID\nextraction omitted TASTE-prefixed rules. Support commented table headers\nin the Codex config helper and include TASTE ids in rule-reference parsing.\n\nConstraint: User config may contain valid TOML comments and generated rule docs now include TASTE rows\nRejected: Ignore commented headers as uncommon | setup would append duplicate [features] tables and break Codex config\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Keep parser helpers aligned with valid user-authored TOML and generated rule id prefixes\nTested: python3 -m py_compile scripts/lib/codex_config_toml.py scripts/lib/vibeguard_manifest.py; bash tests/test_manifest_contract.sh; bash scripts/ci/validate-manifest-contract.sh; bash scripts/verify/doc-freshness-check.sh --strict\nNot-tested: Full remote GitHub Actions rerun after push\n\n* Restore protected Windows check name\n\nBranch protection still requires a check named `CI (windows-latest)`, but\nthis PR renamed the Windows job to `Windows Smoke`. Keep the smoke-only\njob implementation while restoring the protected check name so required\nstatus checks can resolve.\n\nConstraint: main branch protection expects `CI (windows-latest)`\nRejected: Change branch protection instead | workflow naming should remain compatible with existing repository policy\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: If required checks are renamed in workflows, update branch protection in the same change or keep compatibility aliases\nTested: bash scripts/ci/validate-doc-command-paths.sh; bash scripts/ci/validate-manifest-contract.sh; python assertion that workflow contains `name: CI (windows-latest)` and no `name: Windows Smoke`\nNot-tested: Remote GitHub Actions rerun after push",
          "timestamp": "2026-04-19T21:55:31+08:00",
          "tree_id": "569e6666c2f6a40334461b64e319fbb053587bd1",
          "url": "https://github.com/majiayu000/vibeguard/commit/590ddca7e95965040c4648fdfb75816050c36e47"
        },
        "date": 1776607206651,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 192,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 226,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 249,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 312,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 217,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 326,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 217,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 137,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 141,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "9a96f4df6d7cd68c7f64c7bb106254d1dc7eee5d",
          "message": "feat: landing page + GitHub Pages deploy (#86)\n\n* feat(site): landing page + GitHub Pages auto-deploy workflow\n\nAdds starlight-themed landing (site/index.html 10.7 KB, styles.css 11.2 KB,\n8 SVG assets) and workflow to deploy site/ to GitHub Pages on every push to\nmain. Content uses IBM Plex Mono + Space Grotesk + Instrument Serif italic,\nANSI color palette — pulled from the VibeGuard design bundle.\n\nConstraint: docs/ already holds markdown reference docs, so Pages Source\ncannot use /docs folder. Deploy via Actions artifact instead.\nRejected: gh-pages branch (adds history noise) | /docs folder (conflicts)\nConfidence: high\nScope-risk: narrow\nDirective: after merge, enable Settings → Pages → Source = GitHub Actions\n  (one-time manual step) to activate https://majiayu000.github.io/vibeguard/\nTested: site/ serves HTTP 200 locally (10955 B index.html, 11205 B styles.css);\n  workflow YAML validates; isolated via git worktree to avoid mixing with\n  unrelated in-progress changes on docs/scout-2026-04-17.\nNot-tested: GitHub Pages deployment end-to-end (requires Settings flip)\n\n* Prevent branch-picked Pages deployments\n\nManual workflow_dispatch runs can be started from any branch in the Actions UI, while the github-pages environment is shared. Guarding both deployment jobs keeps the landing page publish path tied to reviewed main content.\n\nConstraint: GitHub workflow_dispatch exposes a branch selector that YAML cannot hide\n\nRejected: Remove workflow_dispatch | manual deploys remain useful after switching Pages to Actions\n\nConfidence: high\n\nScope-risk: narrow\n\nDirective: Keep Pages deploy jobs restricted to refs/heads/main unless the environment becomes branch-scoped\n\nTested: ruby YAML.load_file .github/workflows/deploy-pages.yml\n\nTested: git diff --check",
          "timestamp": "2026-04-19T23:15:05+08:00",
          "tree_id": "696a97921d6e65c8bbdd2cbacc26c135af80ce39",
          "url": "https://github.com/majiayu000/vibeguard/commit/9a96f4df6d7cd68c7f64c7bb106254d1dc7eee5d"
        },
        "date": 1776611974993,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 181,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 210,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 230,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 291,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 204,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 303,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 203,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 128,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 128,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "db25d5dfe176b477c9d516232485c9027a39cb5f",
          "message": "Clarify repository boundaries before deeper restructuring (#95)\n\nThe repository looked noisy because public runtime assets, installable workflow surfaces, historical notes, and research artifacts all appeared at similar levels. This change keeps runtime and install contract paths stable while moving historical and research material under docs/internal and documenting ownership in a directory map.\n\nConstraint: setup, manifest, docs, and CI expose root-level runtime paths as public contracts\n\nRejected: Move hooks, guards, rules, scripts, agents, skills, or workflows under src/packages | high path-contract risk for little immediate value\n\nConfidence: high\n\nScope-risk: narrow\n\nReversibility: clean\n\nDirective: Do not relocate product core or workflow surface directories without updating schemas/install-modules.json, setup targets, docs validators, and setup/runtime tests together\n\nTested: bash scripts/ci/validate-manifest-contract.sh; bash scripts/ci/validate-doc-paths.sh; bash scripts/ci/validate-doc-command-paths.sh; bash scripts/verify/doc-freshness-check.sh --strict; bash tests/test_manifest_contract.sh; bash tests/test_setup.sh; bash tests/test_codex_runtime.sh; bash scripts/local-contract-check.sh; git diff --cached --check\n\nNot-tested: GitHub Actions after push",
          "timestamp": "2026-04-20T17:43:09+08:00",
          "tree_id": "88161a045baf5a68d47fb2a5319b1520f5630fa4",
          "url": "https://github.com/majiayu000/vibeguard/commit/db25d5dfe176b477c9d516232485c9027a39cb5f"
        },
        "date": 1776678465581,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 202,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 224,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 249,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 316,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 220,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 332,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 220,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 136,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 138,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "2dd5d3f792416b54423895981df977bad752f8f1",
          "message": "fix(session_metrics): guard env vars against silent KeyError crash (#93)\n\n* fix(session_metrics): guard VIBEGUARD_PROJECT_LOG_DIR and VIBEGUARD_SESSION_ID against KeyError\n\nReplace unguarded os.environ[] accesses with safe alternatives to prevent\nsilent crashes when VIBEGUARD_PROJECT_LOG_DIR is not exported (e.g. standalone\nruns or log.sh failing before export). Exit cleanly via sys.exit(0) when the\ndir is unset. Reuse the already-computed session_id variable for the metrics\ndict instead of re-accessing the env var directly.\n\nCloses #89\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* test(session_metrics): add unit tests for missing env var fallback paths\n\nCover the two guard paths hardened in PR #93:\n- Missing VIBEGUARD_PROJECT_LOG_DIR → early sys.exit(0), no metrics written\n- Missing VIBEGUARD_SESSION_ID → permissive event filter, all sessions accepted\n\nbench_hook_latency.sh always supplies both vars, leaving these branches\nuntested in CI. The four new assertions in run_all.sh exercise exactly\nthe lines the independent reviewer flagged (lines 39 and 161).\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(session_metrics): add early-exit guard for missing VIBEGUARD_SESSION_ID\n\nEmpty session_id caused the event filter to act as wildcard, aggregating\ncross-session events into metrics with an empty session value. Add the\nsame early-exit pattern already used for VIBEGUARD_PROJECT_LOG_DIR.\n\nUpdate tests: case 4 now verifies no metrics file is written on early exit.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-20T17:43:23+08:00",
          "tree_id": "04c2d46b95008d49438818703da4f76f19d623b6",
          "url": "https://github.com/majiayu000/vibeguard/commit/2dd5d3f792416b54423895981df977bad752f8f1"
        },
        "date": 1776678498710,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 186,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 214,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 254,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 295,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 215,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 304,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 128,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 129,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "0bb421d4b4a479e6774827c85bb4c864290cedab",
          "message": "fix(guards): block git checkout/restore with quoted dot argument (#90)\n\n* fix(guards): block git checkout/restore with quoted dot argument\n\nCOMMAND_STRIPPED replaces quoted content with empty strings, so\n`git checkout \".\"` becomes `git checkout \"\"` and evades the guard.\nAlso check COMMAND_PATH_SCAN (which strips quotes but keeps content)\nto catch the quoted-dot bypass variant.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(guards): anchor COMMAND_PATH_SCAN regex to prevent false-positive blocks\n\nCommands like `echo \"git checkout .\"` or commit messages mentioning the\npattern were falsely blocked because the COMMAND_PATH_SCAN regex was not\nanchored to the start of a command segment. After tr strips quotes, the\npattern could match anywhere in the resulting string.\n\nFix: require `git` to appear at the start of the command or after a\ncommand separator (;|&&|||) in the COMMAND_PATH_SCAN grep.\n\nAdd true-positive tests for `git checkout \".\"` and `git restore \".\"`,\nand false-positive guard tests for echo/printf/commit-message mentions.\nAdd corresponding fixture files and meta.json entries.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(guards): close shell-wrapper bypass and quoted-string separator false-positive\n\nReplace the dual COMMAND_STRIPPED / COMMAND_PATH_SCAN check for\ngit checkout/restore with a single COMMAND_STRIPPED_WITH_DOT pass:\n\n1. First replace only isolated \".\" / '.' (standalone quoted dot) with a\n   bare dot — catches `git checkout \".\"` in all wrapper forms (env-var\n   prefix, `env`, `command` builtin, pipe).\n2. Then strip remaining quoted content to empty strings — keeps\n   separators inside commit messages and echo arguments invisible,\n   eliminating the `;`/`&&`/`||` false-positive introduced by the\n   COMMAND_PATH_SCAN (tr -d) approach.\n\nAdds 4 TP fixtures (env-var, env, command, pipe wrappers) and 2 FP\nfixtures (semicolon/&&-inside-commit-message), with matching cases in\ntest_hooks.sh.  All 105 tests pass.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-20T17:43:14+08:00",
          "tree_id": "06c7560a54d6c4ff4df2f6cdd08a538e425fa6ba",
          "url": "https://github.com/majiayu000/vibeguard/commit/0bb421d4b4a479e6774827c85bb4c864290cedab"
        },
        "date": 1776678544607,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 195,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 219,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 274,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 299,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 208,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 316,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 217,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 130,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 136,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "075c3ed9757178180fbc8516cc0f81639afaf224",
          "message": "fix(codex): fail closed on wrapped hook errors (#113)\n\n* fix(codex): fail closed on wrapped hook errors\n\nCodex PreToolUse wrapper execution was failing open when the wrapped hook exited\nnonzero or returned malformed JSON, which disabled guard enforcement instead of\nsurfacing a deny decision. Fail closed for those wrapper errors, keep valid\nempty pass output silent, and cover the failure path with runtime regression\nchecks.\n\nA small vg-helper test-helper cleanup is included so the required cargo test run\nis deterministic: session metrics tests append JSONL, so reusing a fixed temp\nfolder could leave trailing records from earlier runs.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* Keep Codex fail-closed fixes from breaking best-effort hooks\n\nLimit the wrapper hardening to PreToolUse so Stop and other best-effort\nCodex hooks still fail open when they are only advisory, while keeping the\napproval boundary fail closed when hook adaptation breaks.\n\nConstraint: PreToolUse must deny on hook/adaptation failure without changing documented non-blocking Stop/PostToolUse behavior\nRejected: Propagate every nonzero hook exit | it breaks best-effort hook contracts outside the approval boundary\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: When changing Codex hook adaptation, keep explicit tests for both fail-closed PreToolUse and fail-open best-effort hook events\nTested: bash tests/test_codex_runtime.sh; bash tests/test_hook_health.sh; bash tests/test_hooks.sh; cargo check --manifest-path vg-helper/Cargo.toml; cargo test --manifest-path vg-helper/Cargo.toml\nNot-tested: Full CI matrix on GitHub\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(codex): fail closed app-server hook errors\n\nDecline app-server command approvals when pre-bash hooks fail to launch or exit nonzero so broken guards cannot silently bypass the approval boundary.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(codex): return success for deny payloads\n\nCodex only blocks PreToolUse requests when deny JSON is emitted with a successful exit, so keep wrapped-hook and adapter failures fail-closed instead of surfacing them as generic hook failures.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-22T04:40:14+08:00",
          "tree_id": "ade6c358a91910e1a4c48481298c7058163256f8",
          "url": "https://github.com/majiayu000/vibeguard/commit/075c3ed9757178180fbc8516cc0f81639afaf224"
        },
        "date": 1776804311657,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 188,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 213,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 255,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 298,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 208,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 314,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 209,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 132,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 132,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "4933addeb21686e5d59ee12633eed507d8df6e42",
          "message": "fix(pre-commit-guard): detect langs from staged files, not repo config (#92)\n\n* fix(pre-commit-guard): detect langs from staged files, not repo config\n\nDETECTED_LANGS was derived from repo-root config files (Cargo.toml,\ntsconfig.json, …), causing guards for all project languages to run on\nevery commit regardless of what was staged. A TypeScript-only commit in\na mixed Rust/TS repo would falsely block on pre-existing unwrap() calls.\n\nReplace the file-existence checks with grep over $_ALL_STAGED so each\nlanguage guard only runs when at least one file of that language is\nstaged.\n\nFixes #87\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(pre-commit-guard): detect both typescript and javascript in mixed staged commits\n\nReplace elif with independent if for JS detection so a commit containing both\n.ts/.tsx and .js/.jsx files detects and validates both languages. Previously the\nelif branch silently skipped JavaScript syntax checking whenever TypeScript files\nwere staged.\n\nAdd three regression tests:\n- Mixed TS+JS staged: javascript is detected even when TS files are present\n- TS-only staged in a Rust repo: rust not detected from untracked Cargo.toml\n- RS-only staged in a TS repo: typescript not detected from untracked package.json\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(pre-commit-guard): gate root build checks on root manifests\n\nKeep staged-file language detection for quality guards, but only run repo-root build commands when the matching root config exists. This preserves the issue #87 fix while avoiding false failures in nested-module repos and hardens the regression tests around that behavior.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(pre-commit-guard): resolve build roots from the staged tree\n\nPre-commit now discovers TS, Rust, and Go build roots from each staged file's nearest staged manifest so JS-only TS changes and nested packages run the correct validation against the tree being committed.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(pre-commit-guard): restore nested tsc and JS syntax checks\n\nPrefer repo-local TypeScript compilers when resolving nested build roots and keep raw staged JS paths so syntax checks still run for files with spaces.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(pre-commit-guard): keep JS syntax coverage in TS repos\n\nPreserve node --check coverage for staged JS files even when a nearby tsconfig exists,\nand include .mjs/.cjs in staged source detection so invalid module files cannot bypass pre-commit.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* Prevent duplicate TypeScript guard noise on mixed-language commits\n\nThe staged-language detection work correctly keeps build checks scoped to the\nstaged tree, but shared TypeScript quality guards were still dispatched once\nfor `typescript` and again for `javascript` when both were detected. That\nproduced duplicate failures and review noise for mixed TS/JS commits and for\nJS files inside TS projects.\n\nThis change runs the shared TS guard suite once per commit while preserving the\nexisting build-root behavior, and adds deterministic regression coverage for the\ntwo duplicate-execution paths.\n\nConstraint: Keep staged-tree build-root detection behavior from PR #92 intact\nRejected: Remove javascript detection for JS-in-TS paths | would skip node --check coverage\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Keep shared guard dispatch separated from build dispatch when multiple languages reuse one guard family\nTested: bash tests/test_hooks.sh (120/120)\nNot-tested: CI rerun after push\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-24T14:29:36+08:00",
          "tree_id": "9272b80447f5025c59417ec64ddabd7403181607",
          "url": "https://github.com/majiayu000/vibeguard/commit/4933addeb21686e5d59ee12633eed507d8df6e42"
        },
        "date": 1777012481852,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 193,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 218,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 263,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 311,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 214,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 322,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 216,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 136,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 136,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "5779936ce1d7c5ff7ce288854fe927091b0ef1ee",
          "message": "feat(vg-helper): canonical command registry with split exit codes (#104)\n\n* feat(vg-helper): canonical command registry with split exit codes (#102)\n\nReplace the duplicated help-text + dispatch match in main.rs with a\nstatic COMMANDS table (name, usage, handler fn-ptr). Help is now\ngenerated from the registry, so adding a command cannot silently drift\nthe help text. Exit codes are split at the CLI boundary: unknown/missing\ncommand → 2 (user-input error), handler Err → 1 (execution error).\n\nAlso fix a pre-existing test flakiness in session_metrics: parse the\nlast JSONL line rather than the whole file content, which failed on\nrepeated test runs due to file appending in a persistent temp dir.\n\nIntegration tests in tests/cli.rs cover all five contract cases and\ndouble as a registry-completeness assertion (all 8 command names in help).\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(vg-helper): fail malformed JSON at CLI boundary\n\nThe command registry split exit codes at the main entrypoint, but json-field and\njson-two-fields still treated malformed stdin JSON as a blank result. Return\nparse errors instead so invalid input exits 1 while missing fields remain blank.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-24T14:29:54+08:00",
          "tree_id": "6e1b6fb9aef6d15a6da41b5302037c0ef7c2047f",
          "url": "https://github.com/majiayu000/vibeguard/commit/5779936ce1d7c5ff7ce288854fe927091b0ef1ee"
        },
        "date": 1777012493443,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 191,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 229,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 266,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 299,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 215,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 308,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 214,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 137,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 134,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "f7627e1ba0198b8ea0dbdcf4bf7ab5513b152c28",
          "message": "fix(session_metrics): guard VIBEGUARD_LOG_FILE against KeyError (#103) (#105)\n\n* fix(session_metrics): guard VIBEGUARD_LOG_FILE against KeyError on missing env var\n\nReplace bare os.environ[\"VIBEGUARD_LOG_FILE\"] with .get() + early sys.exit(0)\nso invocations without the variable exit silently instead of crashing with a\nKeyError traceback, matching the existing guards for VIBEGUARD_SESSION_ID and\nVIBEGUARD_PROJECT_LOG_DIR added in PR #93.\n\nAdd two test cases to test_session_metrics_env_guard.sh covering exit-0 and\nno-metrics-file-written behaviour when VIBEGUARD_LOG_FILE is unset.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(session_metrics): tighten missing log-file verification\n\nAssert that the missing VIBEGUARD_LOG_FILE guard exits silently, and reset the vg-helper session-metrics test temp dirs so repeated runs do not accumulate stale JSONL state.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-24T14:30:07+08:00",
          "tree_id": "8cbd2102af7b4a7c91ca5ceb3b847aa30cb1adce",
          "url": "https://github.com/majiayu000/vibeguard/commit/f7627e1ba0198b8ea0dbdcf4bf7ab5513b152c28"
        },
        "date": 1777012519784,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 201,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 239,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 296,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 316,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 2925,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 417,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 243,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 156,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 154,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "6c367d3730749ab3c1ffed49084a832ea38d7d2f",
          "message": "Harden rule governance surfaces (#106)\n\n* rules(governance): harden high-context rule surfaces\n\nProtect prompt-bearing files and rule references from silent drift so rule changes stay auditable and parallel agent conflicts surface earlier.\n\nConstraint: High-context files can change agent behavior outside normal business-code review\nRejected: separate hooks per rule family | a single audit script plus lightweight post-edit detection keeps the gate surface smaller\nConfidence: medium\nScope-risk: moderate\nReversibility: clean\nDirective: Extend the shared audit path before adding new standalone gates\nTested: bash -n hooks/post-edit-guard.sh\nTested: python3 -m py_compile scripts/verify/rule-overload-audit.py\nTested: python3 scripts/verify/rule-overload-audit.py\n\n* Improve README scannability with a visual project card\n\nAdd a generated VibeGuard card asset and surface it near the top of README so repository visitors immediately understand the product positioning and core guardrail layers.\n\nConstraint: Keep changes limited to docs presentation without altering product behavior\nConstraint: Use generated bitmap asset and store it inside repository for stable rendering\nRejected: Reuse existing demo GIF as hero visual | too workflow-specific and not card-like\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Keep README card path stable unless docs/assets layout is intentionally reorganized\nTested: Manual render path check in README diff\nTested: bash scripts/ci/validate-doc-paths.sh (repo has pre-existing unrelated failures)\nNot-tested: Cross-platform markdown renderer visual consistency\n\n* Align README hero card with actual VibeGuard capabilities\n\nReplace the README project card image so it reflects the real repository feature map (Native Rules, Hooks, Static Guards, Slash Commands, Learning Loop, Observability, and Claude Code + Codex support) instead of a generic security banner.\n\nConstraint: Keep README reference path unchanged to avoid doc churn\nConstraint: Preserve a single-asset swap with no behavior or script changes\nRejected: Keep prior generic card | did not map to documented capability structure\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: If feature taxonomy changes in README, refresh this card in lockstep\nTested: Visual inspection of docs/assets/readme-card.png\nNot-tested: Rendering differences across all GitHub theme/viewport combinations\n\n* Close PR 106 audit gaps without breaking self-checks\n\nExpand the SEC-13 audit to the repo's real high-context surfaces and make W-14 compare exact event-log file paths. Also escape example trigger text in the canonical security rule so the language validator and audit do not self-flag the rule text itself.\n\nConstraint: Must address PR #106 review threads with a minimal diff\nConstraint: Canonical rules cannot contain CJK text\nRejected: Exclude rule files from SEC-13 scanning | would keep the false-negative path open\nRejected: Keep substring-based W-14 matching | causes false conflicts on shared file prefixes\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: High-context scans should ignore illustrative markdown code spans but continue scanning prose\nTested: bash scripts/ci/validate-canonical-rule-language.sh\nTested: bash scripts/ci/validate-hooks.sh\nTested: bash scripts/ci/validate-rules.sh\nTested: bash scripts/ci/validate-generated-rule-docs.sh\nTested: python3 scripts/verify/rule-overload-audit.py\nNot-tested: Full GitHub Actions matrix rerun\n\n* Close the remaining PR 106 audit false negatives\n\nThe SEC-13 audit now inspects raw high-context text so fenced or inline\nmarkdown cannot hide injected directives, while a line-scoped allowlist\nprevents the canonical security rule from self-triggering on its own\npattern inventory. The W-14 overlap check now normalizes both paths\nbefore exact comparison, and regression coverage locks both cases.\n\nConstraint: Canonical security rules document the same phrases the audit must detect\nRejected: Substring path matching | misflags shared-prefix files as overlaps\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Keep SEC-13 exceptions line-scoped and justified; broaden them only with audit regression coverage\nTested: python3 -m py_compile scripts/verify/rule-overload-audit.py\nTested: bash tests/test_rule_overload_audit.sh\nTested: bash tests/test_hooks.sh\nTested: bash scripts/local-contract-check.sh --quick\nNot-tested: GitHub Actions on the pushed commit\n\n* Prevent SEC-13 audit evasion on marker-example lines\n\nThe audit skipped any line containing the marker phrase to avoid false positives from the canonical security rule. That also let injected overrides hide on the same line in other high-context files. Replace the global skip with an exact path-scoped trusted example allowlist and add regression coverage for a malicious appended override.\n\nConstraint: Canonical security.md intentionally documents dangerous marker phrases\nRejected: Remove all marker-line exemptions | breaks the audit on the trusted SEC-13 rule example\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Keep future SEC-13 exceptions path-scoped and exact-text only; never reintroduce substring-based skips\nTested: python3 -m py_compile scripts/verify/rule-overload-audit.py\nTested: bash tests/test_rule_overload_audit.sh\nTested: bash tests/test_hooks.sh\nNot-tested: Full CI matrix\n\n* Close the escaped SEC-13 audit bypass before merge\n\nNormalize escaped unicode and hex directive text before applying SEC-13 high-risk pattern checks so obfuscated markers cannot slip through high-context scans. Keep the trusted-example allowlist exact and path-scoped, then lock the bypass with regression coverage.\\n\\nConstraint: Must address the remaining PR #106 high-severity review finding with a minimal diff\\nRejected: Broaden trusted-line filtering | reintroduces an evasion path for injected directives\\nConfidence: high\\nScope-risk: narrow\\nReversibility: clean\\nDirective: Keep SEC-13 trusted examples exact-text and path-scoped; normalize escaped markers before risk-pattern matching\\nTested: python3 -m py_compile scripts/verify/rule-overload-audit.py\\nTested: bash tests/test_rule_overload_audit.sh\\nTested: bash tests/test_hooks.sh\\nTested: bash scripts/local-contract-check.sh --quick\\nNot-tested: Full GitHub Actions matrix on the pushed commit",
          "timestamp": "2026-04-24T14:30:22+08:00",
          "tree_id": "78c0dc8a8b2b22781c5b87e805ac8a49baef72b9",
          "url": "https://github.com/majiayu000/vibeguard/commit/6c367d3730749ab3c1ffed49084a832ea38d7d2f"
        },
        "date": 1777012519887,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 182,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 209,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 252,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 341,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 207,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 348,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 131,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 131,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "46525210c21127056069c936a9edc8500912ecc3",
          "message": "fix(codex): include untracked source files in post-build checks (#111)\n\nEnsure the Codex app-server wrapper includes untracked source files when collecting changed paths so post-build-check coverage matches newly created source files, and add a regression test for the untracked-file case.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-24T14:30:37+08:00",
          "tree_id": "692f85fc8eaafdf4f436914efe8cd367bced8365",
          "url": "https://github.com/majiayu000/vibeguard/commit/46525210c21127056069c936a9edc8500912ecc3"
        },
        "date": 1777012528311,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 174,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 246,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 342,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 200,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 338,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 200,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 126,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 125,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "11972cedd8113ace00372417dace90d485ca6b62",
          "message": "fix: fail closed on Codex hook errors (#112)\n\n* Stop Codex app-server approvals from failing open on hook crashes\n\nTreat nonzero pre-bash hook exits as hard guard failures so Codex app-server\nmode cannot implicitly approve commands when the wrapper loses structured hook\noutput. Add a regression test that exercises a crashing pre-bash hook and\nverifies the approval request is declined.\n\nConstraint: Approval hooks must fail closed when guard execution degrades\nRejected: Preserve pass fallback on malformed hook output | it silently disables the guard boundary in app-server mode\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Keep pre-bash approval handling fail-closed for hook crashes and unknown decisions\nTested: cargo check --manifest-path \"vg-helper/Cargo.toml\"; cargo test --manifest-path \"vg-helper/Cargo.toml\"; bash tests/test_codex_runtime.sh\nNot-tested: Full repository shell test matrix\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* Preserve Codex hook warnings while closing launch failures\n\nKeep the app-server wrapper aligned with the pre-bash hook contract so\nwarn-only decisions still pass through, and make hook launch errors\ndecline approvals instead of silently failing open. Add runtime regressions\nfor both paths so future wrapper changes keep the same boundary behavior.\n\nConstraint: Codex app-server approvals must honor the existing pre-bash hook decision contract\nRejected: Treat every non-pass decision as decline | it regresses the documented warn-only path for non-standard .md creation\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: When changing app-server approval interception, keep explicit tests for warn passthrough and hook launch failures\nTested: bash tests/test_codex_runtime.sh; bash scripts/ci/validate-hooks.sh; VIBEGUARD_TEST_UPDATED_INPUT=1 bash tests/test_hooks.sh; python3 -m py_compile scripts/codex/app_server_wrapper.py\nNot-tested: Full CI matrix on GitHub Actions\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* Preserve Codex app-server warning visibility\n\nSurface pre-bash warn reasons through app-server warning notifications and\ncover malformed zero-exit hook decisions so approval warnings stay visible\nwhile unexpected hook output still fails closed.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-24T14:30:51+08:00",
          "tree_id": "b0b0d1fde8f60cd556c140f8270bb3efb2de5b2b",
          "url": "https://github.com/majiayu000/vibeguard/commit/11972cedd8113ace00372417dace90d485ca6b62"
        },
        "date": 1777012661485,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 134,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 165,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 209,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 281,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 158,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 282,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 158,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 93,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 91,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "d50241b039a13c746e606ecd6b18ff3f586b2b79",
          "message": "fix(codex): fail closed on malformed app-server hook JSON (#114) (#115)\n\nTreat non-empty zero-exit hook output with no parsed JSON payload as a hook error so app-server approvals are declined instead of forwarded.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-24T15:11:43+08:00",
          "tree_id": "e4c48b5dae260c4a0f018a31a97fde6348ee750a",
          "url": "https://github.com/majiayu000/vibeguard/commit/d50241b039a13c746e606ecd6b18ff3f586b2b79"
        },
        "date": 1777015045662,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 203,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 240,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 288,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 388,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 234,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 391,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 232,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 145,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 146,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "e8fc1a8b677a40d392bc19c6ec6485804db71cba",
          "message": "fix: fail closed on Codex hook errors (#110)\n\n* Keep Codex app-server approvals closed when hooks fail\n\nDecline approval requests when the pre-bash hook exits nonzero without\nemitting a structured decision so Codex app-server mode cannot bypass\nguard enforcement on hook execution failures. Add a regression test that\nreproduces the failing hook path and proves the wrapper fails closed.\n\nConstraint: Approval hooks must fail closed when runtime wrapper execution breaks\nRejected: Keep default pass on missing decisions | nonzero hook exits silently disabled enforcement\nConfidence: high\nScope-risk: narrow\nReversibility: clean\nDirective: Runtime adapters should treat hook transport failures as declined approvals unless a structured decision overrides them\nTested: bash tests/test_codex_runtime.sh; python3 -m py_compile scripts/codex/app_server_wrapper.py\nNot-tested: End-to-end codex app-server session against a live Codex backend\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(codex): fail closed on hook execution errors\n\nTreat any non-zero pre-bash hook exit as a hook error before parsing decision text so malformed stderr or partial payloads cannot reopen command approvals.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-04-24T20:55:35+08:00",
          "tree_id": "40e3e6fd1fb58380f591e8866274c37faaa6972e",
          "url": "https://github.com/majiayu000/vibeguard/commit/e8fc1a8b677a40d392bc19c6ec6485804db71cba"
        },
        "date": 1777035646727,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 188,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 212,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 254,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 349,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 210,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 346,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 205,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 133,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 131,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "VibeGuard Agent",
            "username": "majiayu000"
          },
          "committer": {
            "email": "1835304752@qq.com",
            "name": "VibeGuard Agent",
            "username": "majiayu000"
          },
          "distinct": true,
          "id": "c6c34feab2959d93816dc0edcaf7e484da0a0869",
          "message": "fix(setup): point scheduled GC templates at canonical script",
          "timestamp": "2026-04-26T17:22:56+08:00",
          "tree_id": "c11e2ca99e77902e0894fa741edd366fa3e24b0f",
          "url": "https://github.com/majiayu000/vibeguard/commit/c6c34feab2959d93816dc0edcaf7e484da0a0869"
        },
        "date": 1777269516647,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 189,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 208,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 254,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 348,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 207,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 351,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 131,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 130,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "d0314516fafc4837a8db947c74bc3052755faed2",
          "message": "fix(codex): clean nested vibeguard.* MCP subtables (#131)\n\nCloses #122.\n\nCleanup logic now matches both `mcp_servers.vibeguard` and any nested table starting with `mcp_servers.vibeguard.` (e.g. `[mcp_servers.vibeguard.env]`), so a stale install no longer leaves child subtables active. Adds regression test in `tests/test_manifest_contract.sh` covering parent + nested children + unrelated sections.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-01T00:01:29+08:00",
          "tree_id": "f9c2ed568053d80de99c64879512d44e00995b11",
          "url": "https://github.com/majiayu000/vibeguard/commit/d0314516fafc4837a8db947c74bc3052755faed2"
        },
        "date": 1777565250683,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 194,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 221,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 268,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 359,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 219,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 366,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 220,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 140,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 137,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "e480c6d629e484719ded349e67db63ad19ad797d",
          "message": "fix(scripts): correct guard_paths.sh source path after subdir reorg (#117)\n\n`compliance_check.sh` and `metrics_collector.sh` were sourcing `lib/guard_paths.sh` from a path that no longer exists after the scripts moved into `scripts/verify/` and `scripts/metrics/`. Two-line fix: prepend `../` so the path resolves to `scripts/lib/guard_paths.sh`.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-01T00:07:23+08:00",
          "tree_id": "8d9b33a56285add503446137aeacca25e4b818bf",
          "url": "https://github.com/majiayu000/vibeguard/commit/e480c6d629e484719ded349e67db63ad19ad797d"
        },
        "date": 1777565558180,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 187,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 226,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 266,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 356,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 214,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 359,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 210,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 130,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 131,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "89857fd04d1562e3d1464b614aaa5f843d1fc5c2",
          "message": "chore: close stale issue 123 already fixed (#129)\n\nCloses #123. The Codex app-server untracked-file gap was already fixed in PR #111 (`4652521`), which added `git ls-files --others --exclude-standard` to `_changed_files()` plus a regression test. This PR documents the verification and closes the issue without duplicating the fix.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-01T00:12:41+08:00",
          "tree_id": "8d9b33a56285add503446137aeacca25e4b818bf",
          "url": "https://github.com/majiayu000/vibeguard/commit/89857fd04d1562e3d1464b614aaa5f843d1fc5c2"
        },
        "date": 1777565861573,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 180,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 210,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 254,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 344,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 209,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 348,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 207,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 131,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 132,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "7b1beb770c759de48880d6657a17913848923133",
          "message": "test(hooks): cover single-quoted quoted-dot guard (#130)\n\nCloses #88. Adds regression coverage for single-quoted dot in `git checkout '.'` and `git restore '.'` across fixture metadata and hook tests. Pure test addition; the guard fix itself already lives on main.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-01T00:20:26+08:00",
          "tree_id": "859b3a71fb91db7e791563f9c6e611fbb52c1616",
          "url": "https://github.com/majiayu000/vibeguard/commit/7b1beb770c759de48880d6657a17913848923133"
        },
        "date": 1777566396147,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 189,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 232,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 256,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 348,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 215,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 344,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 217,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 130,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 130,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "0d43ff20acebb296d8b557e6db98c67f5468cfe1",
          "message": "feat(prompts): add compact chat contract (#124)\n\nCloses #97. Adds a compact chat contract block to claude-md/vibeguard-rules.md, templates/AGENTS.md, and docs/CLAUDE.md.example defining: progress updates (start, post-discovery, pre-edit, post-verify, on blocker), verbosity budgets (concise default, expand on complexity), and formatting rules (prose-first, flat bullets only when natural). Includes idempotency tests across repeated setup cycles.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-01T00:29:03+08:00",
          "tree_id": "7f8f36789411007ded3165d984f20fafa717ec39",
          "url": "https://github.com/majiayu000/vibeguard/commit/0d43ff20acebb296d8b557e6db98c67f5468cfe1"
        },
        "date": 1777566868426,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 198,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 229,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 275,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 356,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 219,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 355,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 219,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 137,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 143,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "d0c5456abfc843d30dd3bb736a88a4798f386fd7",
          "message": "feat(prompts): publish canonical routing contract (#125)\n\nCloses #98. Publishes the canonical routing contract with precedence (user_override → risk gate → ambiguity gate → readiness classifier → execution lane), three readiness outputs (execute_direct / plan_first / clarify_first), and shared handoff fields (mode, artifacts, verification_owner, stop_conditions, lane_map).\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-01T00:35:37+08:00",
          "tree_id": "070b7262034ad0c23a119f6bed6630f0a57b087c",
          "url": "https://github.com/majiayu000/vibeguard/commit/d0c5456abfc843d30dd3bb736a88a4798f386fd7"
        },
        "date": 1777567212043,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 161,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 212,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 279,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 162,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 283,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 158,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 93,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 93,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "f9821dca17f0bc8739e60a8df9d3148d6b727de4",
          "message": "fix(setup): validate codex config health checks (#127)\n\nCloses #120. Adds a `check-codex-hooks` subcommand that parses `~/.codex/config.toml` with tomllib (with tomli / vendored fallback for Python 3.10), rejecting malformed TOML and invalid UTF-8. Replaces the previous regex-only health check that silently passed broken configs.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-01T00:54:31+08:00",
          "tree_id": "a6afd2ce81fe958c73a2de34127a0ddcaf1d73a5",
          "url": "https://github.com/majiayu000/vibeguard/commit/f9821dca17f0bc8739e60a8df9d3148d6b727de4"
        },
        "date": 1777568399872,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 191,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 232,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 274,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 388,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 229,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 377,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 225,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 139,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 141,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "d7494662071fade0675421c88aaa4d8195e7f766",
          "message": "feat(rules): capture 2026-04-27 agentic harness findings (#116)\n\nCaptures three industry findings (NVIDIA AGENTS.md indirect injection, Confident AI / Microsoft AgentRx eval gaps, Augment Code AGENTS.md quality data) into:\n\n- SEC-13 extension: dependency-driven drift protocol (snapshot + diff + quarantine for high-context files created during install/build).\n- W-18: evaluation suites must assert tool selection, step adherence, and confidence calibration — not just final-output equality.\n- New skills: agentsmd-audit (audit-only scoring of five high-leverage AGENTS.md patterns) and the companion update path.\n- Regenerates rules/universal.md and docs/rule-reference.md to match.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-01T01:08:35+08:00",
          "tree_id": "ae72357c6d7d313ba30e2f8fdbcd0d81910b1fd7",
          "url": "https://github.com/majiayu000/vibeguard/commit/d7494662071fade0675421c88aaa4d8195e7f766"
        },
        "date": 1777569224138,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 180,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 210,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 260,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 341,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 346,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 207,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 131,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "994d509408b6915e48db85535ab8ef52de95ed96",
          "message": "feat(universal): add W-19 doc overload guard for CLAUDE.md / AGENTS.md (#118)\n\nAdds W-19 (medium) requiring agent-instruction docs (`CLAUDE.md`, `AGENTS.md`) to stay below sustainable size and pair every prohibition with a concrete example. Detection thresholds: warn >200 / fail >800 lines outside the vibeguard auto-gen region; flag inline mentions of canonical rule IDs (≥3 likely indicates redefinition). Includes `guards/universal/check_doc_overload.sh` plus 10 unit tests.\n\nCodex review was requested but the GitHub connector is currently rate-limited; CI is green on all three platforms and the local test suite (10/10) passes.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-01T01:27:09+08:00",
          "tree_id": "af4459beb64c20d36b968f0d1d30321885ba1047",
          "url": "https://github.com/majiayu000/vibeguard/commit/994d509408b6915e48db85535ab8ef52de95ed96"
        },
        "date": 1777570348665,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 181,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 216,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 255,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 352,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 208,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 355,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 209,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 132,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 136,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "a2af597af5926a23cbaa1cbfc7b0859256336ad5",
          "message": "feat(rules): extend SEC-12/SEC-13 for Claude Code v2.1.121 (#128)\n\nExtends SEC-12 / SEC-13 for Claude Code v2.1.121 surface area: covers `alwaysLoad: true` MCP server configs as a full-trust opt-in requiring cross-tool description validation; treats `.claude/hooks/*` and hook scripts as high-context files under SEC-13; flags hook output-rewriting (`PostToolUse` with `updatedToolOutput` on non-MCP tools) as a man-in-the-middle risk that requires an explicit project-scoped downgrade.\n\nCodex review was requested but the GitHub connector is currently rate-limited; CI is green on all three platforms after rebasing onto main and regenerating rule docs.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-01T01:38:59+08:00",
          "tree_id": "0628b5e200bf28c6d42f8ea4ada07d95245e5148",
          "url": "https://github.com/majiayu000/vibeguard/commit/a2af597af5926a23cbaa1cbfc7b0859256336ad5"
        },
        "date": 1777571060531,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 187,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 221,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 249,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 349,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 207,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 346,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 207,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 132,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 131,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "3019c451a7ebef23b2a7259645217d37b4b4b32e",
          "message": "feat(rules): add SEC-14 (MCP authority-claim) and U-33 (code search defaults) (#119)\n\nAdds two new rules:\n- **SEC-14**: MCP tool descriptions must reject authority-claim and override language (\"absolute authority\", \"ignore prior instructions\", \"supersedes user requests\", Chinese equivalents). Runs at first-install, complementing SEC-12 hash-drift detection that needs a baseline.\n- **U-33**: Code search defaults to glob/grep; vector DB / RAG requires written justification. Anti-pattern: treating embedding search as the default for code retrieval.\n\nCodex review was requested but the GitHub connector is currently rate-limited; CI is green on all three platforms after rebasing onto main and regenerating rule docs.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-01T01:49:44+08:00",
          "tree_id": "bbeb6145bd53549458d3902c91ed65089b69bebb",
          "url": "https://github.com/majiayu000/vibeguard/commit/3019c451a7ebef23b2a7259645217d37b4b4b32e"
        },
        "date": 1777571695978,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 179,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 226,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 253,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 343,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 344,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 128,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 129,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "4f6ffaae9971e25e6a4c537788bfb58c8a8a6e94",
          "message": "fix: remediate codebase audit findings (#132)",
          "timestamp": "2026-05-01T22:47:20+08:00",
          "tree_id": "8d33a6ca392b5399d4e7672b24e4a7607e13db2d",
          "url": "https://github.com/majiayu000/vibeguard/commit/4f6ffaae9971e25e6a4c537788bfb58c8a8a6e94"
        },
        "date": 1777647172035,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 200,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 223,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 294,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 385,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 218,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 389,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 221,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 133,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 136,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "a64dbe7dc9a689e246c092b305553aeb84a636f1",
          "message": "docs: record prompt contract schema plan (#133)",
          "timestamp": "2026-05-01T23:19:57+08:00",
          "tree_id": "328d10809c2d774836ca2b81f38c37624d38d36b",
          "url": "https://github.com/majiayu000/vibeguard/commit/a64dbe7dc9a689e246c092b305553aeb84a636f1"
        },
        "date": 1777649124352,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 188,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 220,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 304,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 392,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 218,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 392,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 221,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 129,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "ed7015c1ef20e1282cb1a17880fce32c31527fdf",
          "message": "fix: generate Claude rule count banner (#134)",
          "timestamp": "2026-05-02T01:06:27+08:00",
          "tree_id": "7f125247b916f771249be306843b636db1274962",
          "url": "https://github.com/majiayu000/vibeguard/commit/ed7015c1ef20e1282cb1a17880fce32c31527fdf"
        },
        "date": 1777655520342,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 186,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 226,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 281,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 379,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 215,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 387,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 218,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 133,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 131,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "e0199153cae116f493971669754c6da8fa4dd94c",
          "message": "ci: update actions for Node 24 runtime (#135)",
          "timestamp": "2026-05-02T01:16:59+08:00",
          "tree_id": "d1e84084f5d467e33b77a1a42f50184a9bc2db1e",
          "url": "https://github.com/majiayu000/vibeguard/commit/e0199153cae116f493971669754c6da8fa4dd94c"
        },
        "date": 1777656142344,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 176,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 234,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 323,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 176,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 328,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 173,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 96,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 97,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "f5fd4542868f7924fb496edfc95ac80fbbf446a8",
          "message": "fix: version session metrics records (#136)",
          "timestamp": "2026-05-02T01:26:11+08:00",
          "tree_id": "76f447221d1099335b8df3a5c88c336a6ed73e0d",
          "url": "https://github.com/majiayu000/vibeguard/commit/f5fd4542868f7924fb496edfc95ac80fbbf446a8"
        },
        "date": 1777656701444,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 226,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 315,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 167,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 316,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 170,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 93,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 93,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "d9cb3017f7089975c50ef94dee97e84f4963c781",
          "message": "fix: archive project event logs in gc (#137)",
          "timestamp": "2026-05-02T01:57:59+08:00",
          "tree_id": "e56b24b32555ba7037e1e05d1e4f200373ce6941",
          "url": "https://github.com/majiayu000/vibeguard/commit/d9cb3017f7089975c50ef94dee97e84f4963c781"
        },
        "date": 1777658622737,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 192,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 222,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 289,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 386,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 221,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 399,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 223,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 134,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 133,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "3f824abb65ec16d951ce400a517517421e378d0a",
          "message": "refactor: split post edit detectors (#138)",
          "timestamp": "2026-05-02T02:13:27+08:00",
          "tree_id": "fb0199fe19e7a87972962e8f977e95955831881c",
          "url": "https://github.com/majiayu000/vibeguard/commit/3f824abb65ec16d951ce400a517517421e378d0a"
        },
        "date": 1777659549613,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 191,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 221,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 290,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 398,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 225,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 405,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 220,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 131,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 131,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "81a5ab00242878791d5e2ffcc822d289d07f8d9e",
          "message": "refactor: split scheduled gc helpers (#139)",
          "timestamp": "2026-05-02T02:39:10+08:00",
          "tree_id": "3e35901921f1d9c2f114114cbbdd6683e3413036",
          "url": "https://github.com/majiayu000/vibeguard/commit/81a5ab00242878791d5e2ffcc822d289d07f8d9e"
        },
        "date": 1777661072768,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 170,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 231,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 328,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 167,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 331,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 167,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 93,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 93,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "cab492900b27a67e3be67e5074dab5c8947b6030",
          "message": "fix: validate project config at runtime (#140)",
          "timestamp": "2026-05-02T03:17:50+08:00",
          "tree_id": "d86c0e910d7c915a9dc338249d7853f81b1c0893",
          "url": "https://github.com/majiayu000/vibeguard/commit/cab492900b27a67e3be67e5074dab5c8947b6030"
        },
        "date": 1777663394883,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 177,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 263,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 332,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 179,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 337,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 175,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 98,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 96,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "f705afb92736e5753e6f003453864585fb1535a9",
          "message": "test: cover log query counters (#141)",
          "timestamp": "2026-05-02T03:28:19+08:00",
          "tree_id": "c73c68e92321ca176e8aed3100e8c57db527ed41",
          "url": "https://github.com/majiayu000/vibeguard/commit/f705afb92736e5753e6f003453864585fb1535a9"
        },
        "date": 1777664058017,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 203,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 265,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 354,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 472,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 257,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 425,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 254,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 142,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "894aeaaa3a15f3d190ba787e84358a8b9d751e7b",
          "message": "test: cover json field helpers (#142)",
          "timestamp": "2026-05-02T03:37:29+08:00",
          "tree_id": "75f95bdb44d20f240c906f0db4ce6704c64d05a7",
          "url": "https://github.com/majiayu000/vibeguard/commit/894aeaaa3a15f3d190ba787e84358a8b9d751e7b"
        },
        "date": 1777664561138,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 177,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 233,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 332,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 177,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 336,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 179,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 99,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 98,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "4df03b043ab528fc03cd654998b43e076c9b31e1",
          "message": "Enforce strict U-22 inventory (#143)\n\n* test: enforce strict u22 inventory\n\n* ci: run strict u22 in self checks",
          "timestamp": "2026-05-02T03:50:01+08:00",
          "tree_id": "fe347cc78cd1f83e3345b61a4f95bc87272e4153",
          "url": "https://github.com/majiayu000/vibeguard/commit/4df03b043ab528fc03cd654998b43e076c9b31e1"
        },
        "date": 1777665339184,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 194,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 223,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 291,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 399,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 223,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 422,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 226,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 136,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 136,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "8ee8f252f58dc2efe35ed6024c7b83bbc8f39b53",
          "message": "Strip heredocs linearly in Bash guard (#144)\n\n* fix: strip heredocs linearly in bash guard\n\n* fix: preserve digit heredoc delimiters",
          "timestamp": "2026-05-02T04:07:17+08:00",
          "tree_id": "9c03eea98af1cc6c247b00d295c834cdcdf67798",
          "url": "https://github.com/majiayu000/vibeguard/commit/8ee8f252f58dc2efe35ed6024c7b83bbc8f39b53"
        },
        "date": 1777666373740,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 198,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 238,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 304,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 419,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 233,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 420,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 232,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 138,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 137,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "9dcd202c3015693ab5e0399a55e07d4676a4d9ae",
          "message": "ci: add sec14 mcp description sentinel (#145)",
          "timestamp": "2026-05-02T06:38:51+08:00",
          "tree_id": "867f90bd419f0447a19f7d891d67469533144c6f",
          "url": "https://github.com/majiayu000/vibeguard/commit/9dcd202c3015693ab5e0399a55e07d4676a4d9ae"
        },
        "date": 1777675471323,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 188,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 221,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 287,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 398,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 219,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 396,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 219,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 130,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 130,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "13d75f58501313e05f1487d361de36af40bc05e8",
          "message": "Remove runtime Python helper fallbacks (#146)",
          "timestamp": "2026-05-02T06:59:00+08:00",
          "tree_id": "aa7c676e7941af0ee2071d56d1c228ead9783f24",
          "url": "https://github.com/majiayu000/vibeguard/commit/13d75f58501313e05f1487d361de36af40bc05e8"
        },
        "date": 1777676688543,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 186,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 201,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 227,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 323,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 199,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 322,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 200,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 131,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 133,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "8750584c3e9c46fcd5e297bad65eaa5da1c30496",
          "message": "Remove legacy Python helper implementations (#147)\n\n* Remove legacy Python helper implementations\n\n* Allowlist removed helper paths in historical docs",
          "timestamp": "2026-05-02T07:11:28+08:00",
          "tree_id": "bce8675669b70bbfa769c945a9ea8a62ab02cccc",
          "url": "https://github.com/majiayu000/vibeguard/commit/8750584c3e9c46fcd5e297bad65eaa5da1c30496"
        },
        "date": 1777677427855,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 193,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 205,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 238,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 331,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 207,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 329,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 208,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 136,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 136,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "1d20c8f6315401d8a1c1e5a3a1f87846c87a453d",
          "message": "docs: refresh Python helper removal plan",
          "timestamp": "2026-05-02T07:22:21+08:00",
          "tree_id": "3a860d088a20c788dae60317d957db91d2c96fb5",
          "url": "https://github.com/majiayu000/vibeguard/commit/1d20c8f6315401d8a1c1e5a3a1f87846c87a453d"
        },
        "date": 1777678154347,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 215,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 226,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 256,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 368,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 227,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 365,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 226,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 145,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "e5c04832f8ab195d113d7266c27c8aad479a8562",
          "message": "ci: guard codex wrapper adapter extraction",
          "timestamp": "2026-05-02T07:32:48+08:00",
          "tree_id": "f453490411574d78c0eb74518dd8b5b3ce7edccc",
          "url": "https://github.com/majiayu000/vibeguard/commit/e5c04832f8ab195d113d7266c27c8aad479a8562"
        },
        "date": 1777678706829,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 197,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 211,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 239,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 338,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 218,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 338,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 209,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 137,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 139,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "aebd4e0ef9685b0d151857d0498514b7a5e3a866",
          "message": "ci: guard package correction argv contract",
          "timestamp": "2026-05-02T08:51:06+08:00",
          "tree_id": "0b66140b7b924531858e9059f9eed3b597526f2d",
          "url": "https://github.com/majiayu000/vibeguard/commit/aebd4e0ef9685b0d151857d0498514b7a5e3a866"
        },
        "date": 1777683416720,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 202,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 214,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 239,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 334,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 205,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 336,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 204,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 159,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "c530abaa932525f24aab9baa2317b30b7e511029",
          "message": "docs: sync low cleanup spec status",
          "timestamp": "2026-05-02T08:59:57+08:00",
          "tree_id": "8b81e25d6b1eb812fe583c1e8dbcc62a2cd924f6",
          "url": "https://github.com/majiayu000/vibeguard/commit/c530abaa932525f24aab9baa2317b30b7e511029"
        },
        "date": 1777683962389,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 233,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 225,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 266,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 358,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 223,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 359,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 232,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 150,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "51523a09b600747122a27798d038b02b8c878f11",
          "message": "log: version runtime event schema",
          "timestamp": "2026-05-02T09:09:55+08:00",
          "tree_id": "1544fcc9da99df4a0e7617537b560cb09cc6469c",
          "url": "https://github.com/majiayu000/vibeguard/commit/51523a09b600747122a27798d038b02b8c878f11"
        },
        "date": 1777684489333,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 174,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 196,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 277,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 278,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 173,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 111,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 111,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "141741e80c2f9246960c72ef02ee0e4433a2b8e5",
          "message": "setup: drive skill installs from manifest",
          "timestamp": "2026-05-02T10:41:31+08:00",
          "tree_id": "2b7d46d0216c1f98f132cb37ddc3c5ebad9e1bf4",
          "url": "https://github.com/majiayu000/vibeguard/commit/141741e80c2f9246960c72ef02ee0e4433a2b8e5"
        },
        "date": 1777690042116,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 200,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 216,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 246,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 348,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 216,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 350,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 215,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 140,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 139,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "92d948df536cfb82e4267a76ee1b5e8759f4ab64",
          "message": "Merge pull request #154 from majiayu000/codex/cleanup-retired-skill-links\n\nsetup: clean retired skill symlinks",
          "timestamp": "2026-05-02T10:58:36+08:00",
          "tree_id": "815f36be67884f34daebd370f033d4f9323f44c3",
          "url": "https://github.com/majiayu000/vibeguard/commit/92d948df536cfb82e4267a76ee1b5e8759f4ab64"
        },
        "date": 1777691085881,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 197,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 204,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 231,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 327,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 203,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 326,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 204,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 133,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 133,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "a834bd9ec23a7d9e2354847f64eb9ecc451f18e5",
          "message": "Merge pull request #155 from majiayu000/codex/close-audit-remediation-plan\n\ndocs: close audit remediation plan",
          "timestamp": "2026-05-02T11:09:46+08:00",
          "tree_id": "782ba906f99dce0440fa76221621aa394289bb52",
          "url": "https://github.com/majiayu000/vibeguard/commit/a834bd9ec23a7d9e2354847f64eb9ecc451f18e5"
        },
        "date": 1777691734953,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 187,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 201,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 227,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 326,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 200,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 322,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 200,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 128,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "8aed3b32c08e5473de20b3dc2619009403d7ddc5",
          "message": "feat(prompts): canonical prompt contract schema + validator (#157)\n\nCloses #96.\n\nLint-only contract for templates/AGENTS.md and agents/*.md role prompts. Catches prompt-shape drift the same way the manifest contract catches manifest drift today.\n\nScope was reduced from the original SPEC after #124 (Chat Contract canonical), #125 (routing contract), and #118 (W-19 size guard) ate ~30-40% of the work. SPEC v2 in plan/spec-96-prompt-contract-schema.md.\n\nAdds:\n- schemas/prompt-contract.schema.json — single source of truth (4 required sections, 2 optional, role frontmatter keys, line budgets)\n- scripts/lib/vibeguard_manifest.py validate-prompt-contract — extends the existing CLI, with role-prompt detection anchored to repo root (not absolute substring)\n- scripts/ci/validate-prompt-contract.sh — walks AGENTS.md + every agents/*.md\n- tests/test_prompt_contract.sh — 15 cases including regressions for codex P1 (relative path) and P2 (ancestor named \"agents\")\n- docs/prompt-contract.md — one-page human reference\n\nMigrates templates/AGENTS.md headings:\n- Constraints + Negative Constraints -> Operating Principles (with Rules / Prohibitions subheadings)\n- Architecture Layers + Fix Priority -> Routing\n- Chat Contract / Verification / Code Style / Guards unchanged\n- Prose unchanged; diff is structural rename only\n\nCodex review: two passes (P1 + P2 on role-prompt detection), both fixed and clean on final commit. CI green on all four platforms.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-05T08:31:28+08:00",
          "tree_id": "bdb1db517dcc2f6631c0ea141cdf1b422eff334d",
          "url": "https://github.com/majiayu000/vibeguard/commit/8aed3b32c08e5473de20b3dc2619009403d7ddc5"
        },
        "date": 1777941439939,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 192,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 202,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 230,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 333,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 204,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 330,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 202,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 132,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 130,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "0920db869480d672c649bfccbda0684c604a1059",
          "message": "Improve Codex usage diagnostics (#156)\n\n* Improve Codex VibeGuard usage diagnostics\n\n- add repo-level AGENTS.md and keep repo-specific facts out of global Codex/Claude templates\n- install and validate managed Codex AGENTS.md rules, semantic drift checks, and a read-only Codex status command\n- add Codex wrapper diagnostics and a single contract gate for Codex runtime checks\n- ensure hooks/_lib/codex_diag.sh is committed with executable mode so CI smoke tests pass\n\nVerification:\n- bash scripts/codex-contract-check.sh\n- bash tests/test_manifest_contract.sh\n- bash setup.sh --check\n- bash setup.sh --codex-status\n- bash tests/test_codex_runtime.sh\n- bash tests/test_codex_status.sh\n- bash tests/test_setup.sh\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(codex-home): skip AGENTS.md inject when diff is SKIP\n\nCodex P2 (codex-home.sh:102): even after `confirm_high_context_write`\nreturned 'SKIP' (already up to date), `claude_md.py inject` still ran\nand rewrote the target file. That contradicts the dry-run promise of\n`setup.sh --dry-run` and could fail when the target AGENTS.md is\nread-only.\n\nAdd an explicit early return when `rules_diff == \"SKIP\"`. The\nconfirmation helper already handled accept/reject for the diff cases;\nthis branch is just the no-op short-circuit.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(codex-hook): parse hook_event_name in diag fallback to keep PreToolUse fail-closed\n\nCodex P2 (run-hook-codex.sh:32): when codex_diag.sh is missing the\nfallback codex_raw_event_name returned an empty string, so all later\nguards of the form [[ \"$EVENT_NAME\" == \"PreToolUse\" ]] never\nfired and the wrapper exited 0 silently — re-introducing the\nfail-open behavior this PR was meant to remove.\n\nUse a pure-bash one-liner that extracts hook_event_name via\nBASH_REMATCH on the raw JSON. This satisfies both:\n- the project's own scripts/ci/self-application/check-codex-wrapper-thin.sh\n  rule (no inline python3 / heredoc adapter logic in the wrapper)\n- the wrapper line ceiling (the file stays at 140 lines, unchanged)\n\nVerification:\n- bash scripts/ci/self-application/run-all.sh → all 7 checks pass\n- bash scripts/codex-contract-check.sh → 14/14 pass\n- bash tests/test_codex_runtime.sh → 48/48 pass\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-06T21:38:35+08:00",
          "tree_id": "bc40257ced3049a90ac26b8503f916a76d0a09f6",
          "url": "https://github.com/majiayu000/vibeguard/commit/0920db869480d672c649bfccbda0684c604a1059"
        },
        "date": 1778075114380,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 183,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 199,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 225,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 318,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 197,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 318,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 196,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 128,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 127,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "3607dafbe5c1ff8ec3b14cef8d43182fbdc18087",
          "message": "fix(hooks): silence pre-write batch advisories + drop Go same-name false positives (#158)\n\n* fix(pre-write-guard): silence batch L1 advisories via circuit breaker\n\nPreToolUse(Write) emitted the warn-mode L1 advisory on every new source\nfile with no session state, so a 6-file batch write injected 6 redundant\n`additionalContext` blocks and forced the agent to acknowledge each one.\nThe fix is also a self-violation cleanup: vg_cb_check was already declared\nin circuit-breaker.sh and used by analysis-paralysis-guard, but never\nwired into pre-write-guard — the exact declared-but-unwired pattern U-26\nforbids.\n\nWire the existing circuit breaker so consecutive notices auto-OPEN after\nCB_THRESHOLD (default 3); subsequent writes pass silently until the\ncooldown expires. Block mode (VIBEGUARD_WRITE_MODE=block) is unchanged so\nhard rejections are never silenced. Advisory text now declares\nACTION: NONE (advisory only) so the agent does not treat it as actionable.\n\nVerification (this session):\n- 5 new tests in test_pre_write_guard.sh confirm CLOSED→OPEN transition\n  at threshold=2.\n- End-to-end smoke run with default threshold=3 over a 6-file batch:\n  writes #1-3 emit advisory, #4-6 silent — 50% reduction in interrupts.\n- Full hook test suite: 15 files, 0 failures.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(post-write-guard): skip same-name detection for Go files\n\nIn Go, every package is a directory and basename collisions across\npackages are routine: internal/foo/config.go vs internal/cli/config.go,\nor many cmd/*/main.go binaries. The OS forbids same-directory same-name,\nso any Go \"same basename\" hit is necessarily cross-package — that is the\nstandard convention, not a duplicate. The L1 same-name check produced\nfalse positives for any new Go file in a multi-package repo.\n\nSkip same-name scanning for .go and rely on Check 2 (duplicate symbol\ndefinitions) to catch real cross-package duplication of struct/func\nnames. Other languages keep existing behavior.\n\nVerification (this session):\n- New test: Go same-named files in different packages no longer emit\n  \"duplicate filename\".\n- Regression guard test: Python same-name across packages still warns,\n  proving the carve-out is Go-only.\n- Full hook test suite: 15 files, 0 failures (post-write-guard 12/12).\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(pre-write-guard): reset breaker on non-advisory writes\n\nCodex P2 (pre-write-guard.sh:160): the warn-mode circuit breaker only\ncalled `vg_cb_record_block` on advisory paths but never called\n`vg_cb_record_pass` on the early-exit pass paths (existing-file edits,\n.md/.json/.yaml/etc., test directories, non-source files). The\nthreshold therefore counted CUMULATIVE session-wide advisories rather\nthan CONSECUTIVE batched-source-file advisories — meaning a user who\ncreated one .go file, did some unrelated config or doc edits, then\ncreated two more .go files would silently lose the next L1 advisory\neven though no real batch was in progress.\n\nSource `circuit-breaker.sh` once near the top, then add a\n`_pass_and_exit` helper that calls `vg_cb_record_pass` before\n`exit 0` on every non-advisory pass branch. Leaves the W-12 and U-16\n\"block\" decisions alone — those intentionally bypass the breaker per\nthe existing code comment.\n\nAdd a regression test asserting that an .md write between two\nthreshold-saturating .go writes resets the counter so the next .go\nwrite still surfaces the L1 advisory.\n\nVerification:\n- bash tests/hooks/test_pre_write_guard.sh → 23/23 PASS (3 new reset cases)\n- bash tests/hooks/test_post_write_guard.sh → 12/12 PASS\n- bash scripts/ci/self-application/run-all.sh → all 7 checks pass\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-07T00:01:20+08:00",
          "tree_id": "207188cb302b878c0b377378d1fc7455f31dd02a",
          "url": "https://github.com/majiayu000/vibeguard/commit/3607dafbe5c1ff8ec3b14cef8d43182fbdc18087"
        },
        "date": 1778083657655,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 193,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 183,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 264,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 155,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 266,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 154,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 96,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 95,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "3b40bcd2f709f8d3151179a032c5762e3a53c48e",
          "message": "fix(setup): pass install state values via argv (#169)",
          "timestamp": "2026-05-11T23:04:45+08:00",
          "tree_id": "40124f8a4f0d8675aac4cece829dadac4a5d4ea6",
          "url": "https://github.com/majiayu000/vibeguard/commit/3b40bcd2f709f8d3151179a032c5762e3a53c48e"
        },
        "date": 1778512257944,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 189,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 246,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 227,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 319,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 199,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 323,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 200,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 128,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 129,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "70edd952d547d12fdbd55d8532ebd0d9a9e551d2",
          "message": "fix(hooks): wire user config into runtime guards (#170)\n\n* fix(hooks): wire user config into runtime guards\n\n* chore(hooks): mark config helper executable\n\n* test(hooks): force non-ci runtime config warning checks",
          "timestamp": "2026-05-11T23:13:14+08:00",
          "tree_id": "083d079aa562b68b2a180419d6a68c25c3d037d2",
          "url": "https://github.com/majiayu000/vibeguard/commit/70edd952d547d12fdbd55d8532ebd0d9a9e551d2"
        },
        "date": 1778512796097,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 232,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 283,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 255,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 355,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 224,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 350,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 219,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 147,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "a851b960068a19d0334cb86a7ad8fe04e3048486",
          "message": "fix(hooks): align W-15 detector with spec — size-delta semantics + downgrade path (#161)\n\n* fix(hooks): align W-15 detector with spec — use size-delta semantics + downgrade path (#160)\n\nW-15's previous implementation only counted consecutive same-file edits\nin the event log, which fired on every long-document workflow (markdown\nspec / RFC / design doc) where each edit naturally targets the same\nfile. The rule's spec, however, asks for *information-yield shrinkage*\nacross three rounds — same-file alone is not the criterion.\n\nThis change reads `len(new_string) - len(old_string)` from the tool\ninput, encodes it in the event-log `detail` field as\n`<file_path>||delta=<N>`, and updates the W-15 detector to fire only\nwhen:\n\n1. three or more consecutive edits target the same file,\n2. `|Δ|` is non-increasing across the three most recent rounds, and\n3. `|Δ_latest| < 300` chars (micro-tuning cap; large content additions\n   never qualify as low-yield).\n\nA `VIBEGUARD_SUPPRESS_W15=1` env var provides the U-32 downgrade path\nthat the rule was previously missing.\n\nThe detail-field encoding is backward-compatible: existing parsers\n(W-14 overlap, churn-count, warn-count, vg-helper log queries) all\nsplit on `||` and only consume the first segment.\n\nTests cover spec compliance (shrinking radius below cap fires),\nmarkdown false-positive regression (growing content does not fire),\nthe `VIBEGUARD_SUPPRESS_W15` downgrade path, the size cap, and\nfail-closed behavior on legacy log entries without delta metadata.\n\nCloses #160\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(hooks): keep W-14 warnings from masking W-15\n\n* test(setup): avoid pipefail false negatives in contains helper\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-11T23:23:13+08:00",
          "tree_id": "3ed3a85a2efbd8631c87d83d44dafcc12ff1b752",
          "url": "https://github.com/majiayu000/vibeguard/commit/a851b960068a19d0334cb86a7ad8fe04e3048486"
        },
        "date": 1778513373943,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 190,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 260,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 232,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 313,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 204,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 335,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 203,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 134,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 134,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "e32516df3c2c8c681bee0cdfdd73df85b843a20f",
          "message": "fix(hooks): gate churn critical on build failures (#171)",
          "timestamp": "2026-05-11T23:31:13+08:00",
          "tree_id": "591bb052f37a53cdf0afc07ab35b49a1fda8462e",
          "url": "https://github.com/majiayu000/vibeguard/commit/e32516df3c2c8c681bee0cdfdd73df85b843a20f"
        },
        "date": 1778513967809,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 282,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 252,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 365,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 223,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 394,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 219,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 146,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "62c7290ea2a7e9621eca3b548208dcd278b0fb39",
          "message": "feat(setup): structured rollup, --quiet, --json, --strict modes for setup.sh --check (#159)\n\nToday `setup.sh --check` prints 40+ lines of mixed [OK]/[INFO]/[BROKEN]\nwithout a summary, no exit code reflecting health, and no machine-readable\noutput. A genuinely broken probe (e.g. zero-byte AGENTS.md) is easy to\nmiss and CI scripts have to grep stdout to detect failure.\n\nThis change introduces a small status reporter library\n(scripts/lib/status_report.sh) and rewrites scripts/setup/check.sh to:\n\n* Always print a Summary table (counts of OK/INFO/WARN/FAIL/BROKEN/MISSING)\n  and a final Verdict line of HEALTHY / DEGRADED / BROKEN.\n* Add --quiet to suppress healthy rows and surface only problems plus\n  the rollup, for triage in long install logs.\n* Add --json to emit a stable schema_version=1 document with counts,\n  verdict, and the full event list for CI consumers and the\n  /vibeguard:check skill. Implies --strict.\n* Add --strict to reflect health in the exit code (0 healthy, 1 degraded,\n  2 broken). Default mode keeps the historical always-exit-0 contract\n  so test_setup.sh and existing downstream callers do not regress.\n* Add --no-summary as an explicit escape hatch for any consumer that\n  grepped the prior unsummarized output.\n* Fix a latent bug in install.sh where `--check`/`--clean` swallowed\n  trailing arguments before forwarding to the target script.\n\nThe legacy free-form `[LEVEL] message` lines are preserved verbatim so\nexisting tests and tooling that grep them keep working. Tally is computed\nby post-processing the captured stdout, which means zero changes to the\ndozens of `green/yellow/red \"[LEVEL] ...\"` call sites in lib.sh and\ntargets/*.sh.\n\ntests/test_setup_check.sh covers tally arithmetic, ANSI stripping, JSON\nshape (parse-driven, not substring), exit-code policy, argument parsing\nerrors, and end-to-end behavior. The full pre-existing test_setup.sh\nsuite (171 cases) continues to pass unchanged.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>",
          "timestamp": "2026-05-12T00:08:22+08:00",
          "tree_id": "aeccd4ee5b57a0f180df7341b7b60be5f31b9fe6",
          "url": "https://github.com/majiayu000/vibeguard/commit/62c7290ea2a7e9621eca3b548208dcd278b0fb39"
        },
        "date": 1778516105369,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 211,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 290,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 253,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 371,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 239,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 403,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 227,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 150,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "9a266f8e5116c77c336778ced369da7beb1452b7",
          "message": "fix(sec13): scan risky MCP trust fields (#172)",
          "timestamp": "2026-05-12T00:22:15+08:00",
          "tree_id": "64de6d9864af0f2d4cd192fdd4bee22ce71ed1b0",
          "url": "https://github.com/majiayu000/vibeguard/commit/9a266f8e5116c77c336778ced369da7beb1452b7"
        },
        "date": 1778516949865,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 204,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 279,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 248,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 362,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 218,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 387,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 219,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 165,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 142,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "1101d40cf09de95a428efc0e231daedf4c8a76dd",
          "message": "fix(u32): enforce live constraint budget (#173)",
          "timestamp": "2026-05-12T00:51:19+08:00",
          "tree_id": "4e1631cd95a5a0a0d9a4cf71ec0468f916408b55",
          "url": "https://github.com/majiayu000/vibeguard/commit/1101d40cf09de95a428efc0e231daedf4c8a76dd"
        },
        "date": 1778518699203,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 203,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 278,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 248,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 361,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 216,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 386,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 216,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 143,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "4f853b14817d3e595fe27be7f154b2916209cc4b",
          "message": "fix(sec11): expand AI review gates (#174)",
          "timestamp": "2026-05-12T16:40:54+08:00",
          "tree_id": "5cb1a42b22e8e75eff9edbe110bcbbf948e84e8a",
          "url": "https://github.com/majiayu000/vibeguard/commit/4f853b14817d3e595fe27be7f154b2916209cc4b"
        },
        "date": 1778575723675,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 203,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 279,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 247,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 360,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 218,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 389,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 222,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 147,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 143,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "2a256b0ddd33666914b4099a3f2d6dac1f6886aa",
          "message": "fix(hooks): keep circuit breaker lock path for trap release (#176)\n\nCo-authored-by: Lifcc <lifcc@Agent-OS.local>",
          "timestamp": "2026-05-12T16:57:41+08:00",
          "tree_id": "c1c84b0e324aff1f2f98e4c6f3b8096ce67864ad",
          "url": "https://github.com/majiayu000/vibeguard/commit/2a256b0ddd33666914b4099a3f2d6dac1f6886aa"
        },
        "date": 1778576640776,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 188,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 256,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 228,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 331,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 201,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 353,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 201,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 134,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 133,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "8d928722fcc65fe36145319cfff1fb896fca791b",
          "message": "feat(workflow): add execution pinning guard (#177)\n\nCo-authored-by: Lifcc <lifcc@Agent-OS.local>",
          "timestamp": "2026-05-12T17:30:55+08:00",
          "tree_id": "f9599e5bfe961f20ca2c7167f14584e7a4659d9a",
          "url": "https://github.com/majiayu000/vibeguard/commit/8d928722fcc65fe36145319cfff1fb896fca791b"
        },
        "date": 1778578658485,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 186,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 256,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 228,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 331,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 201,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 357,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 206,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 135,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 135,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "e128c2f85cae2e6f936e2bc25749b7eec7568dfd",
          "message": "docs(workflow): formalize delegation contract (#179)\n\nCo-authored-by: Lifcc <lifcc@Agent-OS.local>",
          "timestamp": "2026-05-12T17:52:16+08:00",
          "tree_id": "98199f53dea18adccbadb44b9038a27a003e0359",
          "url": "https://github.com/majiayu000/vibeguard/commit/e128c2f85cae2e6f936e2bc25749b7eec7568dfd"
        },
        "date": 1778579928233,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 195,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 264,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 232,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 340,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 209,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 366,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 205,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 135,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 137,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "2bc89d1cae5b169ebc99bb19351f2245801ab49f",
          "message": "Add Rust Codex gates and optimize hooks (#191)\n\n* fix(pre-write-guard): silence batch L1 advisories via circuit breaker\n\nPreToolUse(Write) emitted the warn-mode L1 advisory on every new source\nfile with no session state, so a 6-file batch write injected 6 redundant\n`additionalContext` blocks and forced the agent to acknowledge each one.\nThe fix is also a self-violation cleanup: vg_cb_check was already declared\nin circuit-breaker.sh and used by analysis-paralysis-guard, but never\nwired into pre-write-guard — the exact declared-but-unwired pattern U-26\nforbids.\n\nWire the existing circuit breaker so consecutive notices auto-OPEN after\nCB_THRESHOLD (default 3); subsequent writes pass silently until the\ncooldown expires. Block mode (VIBEGUARD_WRITE_MODE=block) is unchanged so\nhard rejections are never silenced. Advisory text now declares\nACTION: NONE (advisory only) so the agent does not treat it as actionable.\n\nVerification (this session):\n- 5 new tests in test_pre_write_guard.sh confirm CLOSED→OPEN transition\n  at threshold=2.\n- End-to-end smoke run with default threshold=3 over a 6-file batch:\n  writes #1-3 emit advisory, #4-6 silent — 50% reduction in interrupts.\n- Full hook test suite: 15 files, 0 failures.\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* fix(post-write-guard): skip same-name detection for Go files\n\nIn Go, every package is a directory and basename collisions across\npackages are routine: internal/foo/config.go vs internal/cli/config.go,\nor many cmd/*/main.go binaries. The OS forbids same-directory same-name,\nso any Go \"same basename\" hit is necessarily cross-package — that is the\nstandard convention, not a duplicate. The L1 same-name check produced\nfalse positives for any new Go file in a multi-package repo.\n\nSkip same-name scanning for .go and rely on Check 2 (duplicate symbol\ndefinitions) to catch real cross-package duplication of struct/func\nnames. Other languages keep existing behavior.\n\nVerification (this session):\n- New test: Go same-named files in different packages no longer emit\n  \"duplicate filename\".\n- Regression guard test: Python same-name across packages still warns,\n  proving the carve-out is Go-only.\n- Full hook test suite: 15 files, 0 failures (post-write-guard 12/12).\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\n\n* feat: add Rust Codex gates and optimize hooks\n\n* test: cover codex gate modules\n\n* bench: report p99 hook latency\n\n* refactor: rename rust runtime\n\n* fix: address rust runtime review comments\n\n* fix: exclude churn-only fast warnings\n\n* fix: guard standard app-server file changes\n\n* fix: align codex review contracts\n\n* fix: harden hook log redaction\n\n* fix: serialize rust jsonl appends\n\n* fix: keep churn-only warnings non-escalating\n\n* fix: address app-server completion review\n\n* fix: address fast path review comments\n\n* fix: tighten existing log directory permissions\n\n---------\n\nSigned-off-by: majiayu000 <1835304752@qq.com>\nCo-authored-by: Lifcc <lifcc@Agent-OS.local>",
          "timestamp": "2026-05-16T14:26:38+08:00",
          "tree_id": "1c668395bedd45bf5410316711074baf47542169",
          "url": "https://github.com/majiayu000/vibeguard/commit/2bc89d1cae5b169ebc99bb19351f2245801ab49f"
        },
        "date": 1778913177182,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 102,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 102,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 65,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 65,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 134,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 134,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 23,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "370038d00e3a596ecce849c1507c7bab94153878",
          "message": "fix: address high-priority setup and hook contract issues (#209)\n\nMerges validated setup and hook contract fixes. Closes #181, #183, #189, #190, and #202.",
          "timestamp": "2026-05-18T10:50:04+08:00",
          "tree_id": "6f1c47e38fdb5e3e63a2c927ca14a4338d88cec3",
          "url": "https://github.com/majiayu000/vibeguard/commit/370038d00e3a596ecce849c1507c7bab94153878"
        },
        "date": 1779072979301,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 87,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 87,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 59,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 59,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 122,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 122,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 128,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 128,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "0eea1e944e07ab6fe5ae4d61f464b5795c7eb241",
          "message": "feat: add native Codex hook enforcement and diagnostics (#193)\n\nAdd native Codex hook setup/runtime coverage, migrate config handling to the current hooks feature flag contract, and keep the Codex wrapper thin by moving the execution loop into a reusable runner.\\n\\nFixes #182.\\nFixes #203.\\n\\nValidation: GitHub Actions run 26011654890 passed for macOS, Ubuntu, Windows, Self-Application CI, and Benchmark Report.",
          "timestamp": "2026-05-18T11:27:25+08:00",
          "tree_id": "92a0cfd1b057f7d5a76fcc56fe15be697f3fbb7a",
          "url": "https://github.com/majiayu000/vibeguard/commit/0eea1e944e07ab6fe5ae4d61f464b5795c7eb241"
        },
        "date": 1779075270482,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 97,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 97,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 63,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 63,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 136,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 136,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "c7f21a11672eb601f0fa29b1cc0d53ebc77307a1",
          "message": "test: cover pre-write missing runtime failure (#216)\n\nAdd a regression test for the hooks-only missing-runtime scenario so pre-write cannot silently pass W-12/new-source writes when vibeguard-runtime is unavailable.\\n\\nFixes #215.\\n\\nValidation: GitHub Actions run 26011973955 passed for macOS, Ubuntu, Windows, Self-Application CI, and Benchmark Report.",
          "timestamp": "2026-05-18T11:38:24+08:00",
          "tree_id": "1115e9d7b1eb3fda1e832262644a5ceb6a903cfb",
          "url": "https://github.com/majiayu000/vibeguard/commit/c7f21a11672eb601f0fa29b1cc0d53ebc77307a1"
        },
        "date": 1779075912216,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 88,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 88,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 62,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 62,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 123,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 123,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 131,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 131,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "134ad75947d74aecadbf7549f21fe177b27a7155",
          "message": "fix: detect stale hook registrations\n\nDetect and repair stale Claude/Codex hook registrations that point at removed installed hook scripts. Fixes #188.",
          "timestamp": "2026-05-18T12:05:19+08:00",
          "tree_id": "6efd58fcfc7a8339abc8e4d81b57a205c72fbc60",
          "url": "https://github.com/majiayu000/vibeguard/commit/134ad75947d74aecadbf7549f21fe177b27a7155"
        },
        "date": 1779077517590,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 88,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 88,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 59,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 59,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 123,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 123,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 130,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 130,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "563c70ea7c1e1da9c952ec081e61d99188029c0c",
          "message": "Fix hook caller identity logging",
          "timestamp": "2026-05-18T12:28:36+08:00",
          "tree_id": "2a63ccbb6d457ae40c89c678ec1f07c70b5cf6de",
          "url": "https://github.com/majiayu000/vibeguard/commit/563c70ea7c1e1da9c952ec081e61d99188029c0c"
        },
        "date": 1779078924151,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 107,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 107,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "681fab181675e6d3e78ae9569ab83870ca1647de",
          "message": "Add authorized discard workflow",
          "timestamp": "2026-05-18T12:50:22+08:00",
          "tree_id": "6540ec919d185c2b4abffff5755943f0a96ad794",
          "url": "https://github.com/majiayu000/vibeguard/commit/681fab181675e6d3e78ae9569ab83870ca1647de"
        },
        "date": 1779080235740,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 107,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 107,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 81,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 81,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 140,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 140,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "0e4f3e649479cd52f36dda915b5acf6d4de8a885",
          "message": "Enforce hook latency budget contract (#220)\n\n* test: enforce hook latency contract\n\nFixes #184\n\n* test: enforce hook latency contract\n\nFixes #184",
          "timestamp": "2026-05-18T14:22:02+08:00",
          "tree_id": "2adaa6ff22ec4c2116ff719c50144b8d2a0ab3f0",
          "url": "https://github.com/majiayu000/vibeguard/commit/0e4f3e649479cd52f36dda915b5acf6d4de8a885"
        },
        "date": 1779085733993,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 88,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 111,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 111,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 157,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 157,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "066f7977a7466b5360f9a724748821ba0f866306",
          "message": "Add live-truth verification gates (#221)\n\nFixes #186",
          "timestamp": "2026-05-18T14:53:27+08:00",
          "tree_id": "48ce3201673d7db41baaeb76f85a547a7baef1aa",
          "url": "https://github.com/majiayu000/vibeguard/commit/066f7977a7466b5360f9a724748821ba0f866306"
        },
        "date": 1779087660910,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 83,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 108,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 108,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "f548aea9d12dcd754e075326d613a44da8975c12",
          "message": "Add skill validation evidence gate (#222)\n\nFixes #192",
          "timestamp": "2026-05-18T15:22:34+08:00",
          "tree_id": "356cd2c23cfaf31560f7ca68a87bac50b800e208",
          "url": "https://github.com/majiayu000/vibeguard/commit/f548aea9d12dcd754e075326d613a44da8975c12"
        },
        "date": 1779089393138,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 92,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 118,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 118,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 75,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 75,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 159,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 159,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 165,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 165,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "a44fec0f24219c2e34a94931246fd3e4cad35eef",
          "message": "Validate hook component registry drift (#223)\n\nFixes #194",
          "timestamp": "2026-05-18T15:52:02+08:00",
          "tree_id": "02eb7635487240dca7f9755e543748fe00a45b18",
          "url": "https://github.com/majiayu000/vibeguard/commit/a44fec0f24219c2e34a94931246fd3e4cad35eef"
        },
        "date": 1779091142141,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 85,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 110,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 110,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "6cacadf3ba7a693cbe1f77b803ea25fb4035b418",
          "message": "Enforce runtime hook policy contract\n\nCloses #195",
          "timestamp": "2026-05-18T16:30:34+08:00",
          "tree_id": "55c3c13ae62e815d9474452dce6cd275ac2ad60f",
          "url": "https://github.com/majiayu000/vibeguard/commit/6cacadf3ba7a693cbe1f77b803ea25fb4035b418"
        },
        "date": 1779093458771,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 90,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 116,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 116,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 162,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 162,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "d9c41f5b8cf37df10b982d6fdd2e3e8632ac20cf",
          "message": "Make runtime failures visible by event\n\nCloses #196",
          "timestamp": "2026-05-18T16:58:20+08:00",
          "tree_id": "10fb454b4ca3a022d12b19c4644b2543c9af27d2",
          "url": "https://github.com/majiayu000/vibeguard/commit/d9c41f5b8cf37df10b982d6fdd2e3e8632ac20cf"
        },
        "date": 1779095150260,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 85,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 110,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 110,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 70,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "majiayu000",
            "username": "majiayu000"
          },
          "committer": {
            "email": "1835304752@qq.com",
            "name": "majiayu000",
            "username": "majiayu000"
          },
          "distinct": true,
          "id": "cc918cff84b0656b59e2d665a8c61ff2678ce320",
          "message": "Clarify optional Codex app-server wrapper",
          "timestamp": "2026-05-18T17:07:02+08:00",
          "tree_id": "4a3db05086ad576eaddbdfaaf406c63c8696100c",
          "url": "https://github.com/majiayu000/vibeguard/commit/cc918cff84b0656b59e2d665a8c61ff2678ce320"
        },
        "date": 1779095750711,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 87,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 112,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 112,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 155,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 155,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "b8af86ae7db9da0acd0c227bbaa46ab766756f51",
          "message": "Add versioned eval harness artifacts\n\nCloses #197",
          "timestamp": "2026-05-18T17:56:42+08:00",
          "tree_id": "bc7b7e27078f302c40c23b2431aebfe0372709ba",
          "url": "https://github.com/majiayu000/vibeguard/commit/b8af86ae7db9da0acd0c227bbaa46ab766756f51"
        },
        "date": 1779098685850,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 85,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 113,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 113,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 70,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 75,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 75,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 145,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 145,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "73b783f799731a5860f3701be5db76f6da52f09b",
          "message": "Add behavior eval regression gate\n\nCloses #198",
          "timestamp": "2026-05-18T18:26:46+08:00",
          "tree_id": "8d0a711a64c290c4d4926c623e37b6bfd60a0726",
          "url": "https://github.com/majiayu000/vibeguard/commit/73b783f799731a5860f3701be5db76f6da52f09b"
        },
        "date": 1779100472382,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 83,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 105,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 105,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "e993fb66416fb79751fb93506fd423be089f0e11",
          "message": "Add executable workflow contract schemas\n\nCloses #199",
          "timestamp": "2026-05-18T19:01:33+08:00",
          "tree_id": "04f5d466cc6ca7e87ce0bb503c0c4224952c13f2",
          "url": "https://github.com/majiayu000/vibeguard/commit/e993fb66416fb79751fb93506fd423be089f0e11"
        },
        "date": 1779102540778,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 94,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 118,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 118,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 154,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 154,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 165,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 165,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 23,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "5b27edcf0555333dd3dace8fdc514ccbb56b66ee",
          "message": "Harden setup config handling\n\nCloses #200",
          "timestamp": "2026-05-18T19:36:00+08:00",
          "tree_id": "94894e29a5aca534ccda7dec3871cd60e979de10",
          "url": "https://github.com/majiayu000/vibeguard/commit/5b27edcf0555333dd3dace8fdc514ccbb56b66ee"
        },
        "date": 1779104610184,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 84,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 106,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 106,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 139,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 139,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "d494ce4d880396d4486009f0f42d4c427ceb30c8",
          "message": "Add SEC-17 third-party skill safety rule\n\nCloses #204",
          "timestamp": "2026-05-18T19:56:55+08:00",
          "tree_id": "3e5eff435f7188048c63e02e79379f2f4d217b5c",
          "url": "https://github.com/majiayu000/vibeguard/commit/d494ce4d880396d4486009f0f42d4c427ceb30c8"
        },
        "date": 1779105845974,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 85,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 108,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 108,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 145,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 145,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "d80cc059311539351ff876b30d676248b8f595f1",
          "message": "Add SEC-16 AI patch safety policy\n\nCloses #208",
          "timestamp": "2026-05-18T20:15:14+08:00",
          "tree_id": "56b0f5bfe0868c509411b717940bd25c79bd29ac",
          "url": "https://github.com/majiayu000/vibeguard/commit/d80cc059311539351ff876b30d676248b8f595f1"
        },
        "date": 1779107084922,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 84,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 104,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 104,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 66,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 139,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 139,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 147,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 147,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "4c100882003df1b8c46d0f2900ce8ed75ac83e6f",
          "message": "Add SEC-18 semantic input safety rule\n\nCloses #214",
          "timestamp": "2026-05-18T20:36:31+08:00",
          "tree_id": "72d4cf04be7b1773f5357e98194e2abe86de9d73",
          "url": "https://github.com/majiayu000/vibeguard/commit/4c100882003df1b8c46d0f2900ce8ed75ac83e6f"
        },
        "date": 1779108284641,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 83,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 108,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 108,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 156,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 156,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "8463fe9627b9a7022430cbc7428d01fc8c7b030e",
          "message": "Promote W-19 doc hygiene rule to strict\n\nCloses #224",
          "timestamp": "2026-05-18T20:53:36+08:00",
          "tree_id": "1ac178592a9944480af774089079b082acc3c99b",
          "url": "https://github.com/majiayu000/vibeguard/commit/8463fe9627b9a7022430cbc7428d01fc8c7b030e"
        },
        "date": 1779109297642,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 83,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 108,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 108,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "4a8e20cafb95e1c00b2931c149d4d5e2bb2b10c1",
          "message": "Merge pull request #235 from majiayu000/codex/w37-agent-learning-memory\n\nAdd W-37 agent learning memory rule",
          "timestamp": "2026-05-18T21:14:15+08:00",
          "tree_id": "c3d3810d1ab5610ed4d5d1deceb2d4519d19f171",
          "url": "https://github.com/majiayu000/vibeguard/commit/4a8e20cafb95e1c00b2931c149d4d5e2bb2b10c1"
        },
        "date": 1779110594293,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 80,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 103,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 103,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 66,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 140,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 140,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "a5f19099146042cf5734ea84b102b7514a3459c2",
          "message": "Merge pull request #236 from majiayu000/codex/w38-tool-use-metrics\n\nAdd W-38 tool-use metrics rule",
          "timestamp": "2026-05-18T21:36:55+08:00",
          "tree_id": "551b4188bc1fe6aeee839dadfbee7877cb9d4d20",
          "url": "https://github.com/majiayu000/vibeguard/commit/a5f19099146042cf5734ea84b102b7514a3459c2"
        },
        "date": 1779111810959,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 88,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 88,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 55,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 56,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 56,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 117,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 117,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 125,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 125,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 17,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "bfd9aeaf7566b4f3bde6da15e5c4df4c4720b4fc",
          "message": "Merge pull request #237 from majiayu000/codex/w42-artifact-fidelity-checkpoints\n\nAdd W-42 artifact fidelity checkpoints rule",
          "timestamp": "2026-05-18T21:54:54+08:00",
          "tree_id": "c21a45352fb5a948a20dbdd5bbaed3904518d8fe",
          "url": "https://github.com/majiayu000/vibeguard/commit/bfd9aeaf7566b4f3bde6da15e5c4df4c4720b4fc"
        },
        "date": 1779112947621,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 87,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 113,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 113,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 70,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 70,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 70,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 156,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 156,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "e30369b0c3ac97abf2e144e8d9deb674f517bc72",
          "message": "Merge pull request #238 from majiayu000/codex/w30-harness-audit-axes\n\nAdd W-30 agent harness audit rule",
          "timestamp": "2026-05-18T22:13:56+08:00",
          "tree_id": "c82221ad00c6b1ff3684b666bb7f6a3ee74c821c",
          "url": "https://github.com/majiayu000/vibeguard/commit/e30369b0c3ac97abf2e144e8d9deb674f517bc72"
        },
        "date": 1779114097283,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 87,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 110,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 110,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 70,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 147,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 147,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "7f03b62375646c369569d3f74439d6d6c60250b6",
          "message": "Merge pull request #239 from majiayu000/codex/u33-structural-navigation-threshold\n\nRevise U-33 large codebase retrieval guidance",
          "timestamp": "2026-05-18T22:35:29+08:00",
          "tree_id": "ac020a20c96043cb5650885a1978e577fce2138d",
          "url": "https://github.com/majiayu000/vibeguard/commit/7f03b62375646c369569d3f74439d6d6c60250b6"
        },
        "date": 1779115464730,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 93,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 120,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 120,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 77,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 78,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 78,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 158,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 158,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 165,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 165,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 24,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "b2ba12e2321b7aacd527fc264c87a9f60ef43fbb",
          "message": "Merge pull request #241 from majiayu000/codex/fix-codex-wrapper-eof-drain\n\nFix Codex app-server EOF drain race",
          "timestamp": "2026-05-18T23:10:05+08:00",
          "tree_id": "18c9b84fb2da32cc909a1daf58b5a1a0331002dd",
          "url": "https://github.com/majiayu000/vibeguard/commit/b2ba12e2321b7aacd527fc264c87a9f60ef43fbb"
        },
        "date": 1779117422619,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 81,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 105,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 105,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 138,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 138,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "ede1c7211f3ccbc9cc01bdcb3a3ce8fe6052cc10",
          "message": "Add skill format validation gate (#244)\n\n* Add skill format validation gate\n\n* Fix skill format markdown link list items",
          "timestamp": "2026-05-22T20:10:31+08:00",
          "tree_id": "a09c8f87336dc5a25b06c0c3f4255c20b0f7d095",
          "url": "https://github.com/majiayu000/vibeguard/commit/ede1c7211f3ccbc9cc01bdcb3a3ce8fe6052cc10"
        },
        "date": 1779452307688,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 93,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 117,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 117,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 75,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 75,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 156,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 156,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 164,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 164,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "e4c170d19cfc3b27b015c1f53481df6378d92093",
          "message": "Merge pull request #245 from majiayu000/codex/skill-format-gate\n\nAdd VibeGuard skill format gate",
          "timestamp": "2026-05-25T16:38:03+08:00",
          "tree_id": "cd05b227c195b8ec98dbf6354bed890cc5f01a11",
          "url": "https://github.com/majiayu000/vibeguard/commit/e4c170d19cfc3b27b015c1f53481df6378d92093"
        },
        "date": 1779698724832,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 91,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 114,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 114,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 164,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 164,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "f7acef64a3694da5c49a46400c36f73708ef6700",
          "message": "Merge pull request #254 from majiayu000/feature/pre-edit-suggest-candidates\n\npre-edit: suggest fuzzy-match candidates when file missing",
          "timestamp": "2026-05-25T16:46:44+08:00",
          "tree_id": "59a83f2bb4b4e24ebd7bbe67de5c0828ae70e915",
          "url": "https://github.com/majiayu000/vibeguard/commit/f7acef64a3694da5c49a46400c36f73708ef6700"
        },
        "date": 1779699222970,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 82,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 105,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 105,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "c8276898d55ebf15b38fe2eec47da76a1a70ed00",
          "message": "Merge pull request #248 from majiayu000/codex/fix-eval-prompt-label-leak\n\nfix(eval): stop leaking expected actions",
          "timestamp": "2026-05-25T16:56:58+08:00",
          "tree_id": "7c7f7922f59b9ed4b4886b993efe7f5fea9b956d",
          "url": "https://github.com/majiayu000/vibeguard/commit/c8276898d55ebf15b38fe2eec47da76a1a70ed00"
        },
        "date": 1779699790564,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 91,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 91,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 58,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 58,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 58,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 121,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 121,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 17,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "fa8aedd520759e86206aa966e92f2b92ce3f5231",
          "message": "Merge pull request #250 from majiayu000/feature/wt-base-config\n\nworktree: configurable base path + actionable W-14 hint",
          "timestamp": "2026-05-25T17:21:40+08:00",
          "tree_id": "ddc15dd4163a5f438fd00877642effd34ad89b1b",
          "url": "https://github.com/majiayu000/vibeguard/commit/fa8aedd520759e86206aa966e92f2b92ce3f5231"
        },
        "date": 1779701334786,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 89,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 115,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 115,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 159,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 159,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "2f542d082661ab71234d0ff1362fd93bca18a053",
          "message": "Merge pull request #252 from majiayu000/feature/w15-skip-doc-paths\n\nw15: skip markdown / notes / changelog paths",
          "timestamp": "2026-05-25T17:30:40+08:00",
          "tree_id": "577b0d0215ce9897af2eb259a9a35a75c7e679cd",
          "url": "https://github.com/majiayu000/vibeguard/commit/2f542d082661ab71234d0ff1362fd93bca18a053"
        },
        "date": 1779701893161,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 89,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 115,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 115,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 159,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 159,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "8752af4be9ddb601322b6db5379cb6351958db40",
          "message": "Merge pull request #256 from majiayu000/feature/pre-write-escalation\n\npre-write: escalate to block after N unheeded L1 advisories",
          "timestamp": "2026-05-25T17:39:23+08:00",
          "tree_id": "5f8ad43ad6a00cd6fdfab9beb68176ffb67db545",
          "url": "https://github.com/majiayu000/vibeguard/commit/8752af4be9ddb601322b6db5379cb6351958db40"
        },
        "date": 1779702382345,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 127,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 140,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 140,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "b3ae510b93fab05e9bb0c0e8ba04c8bf0f1dd8d1",
          "message": "Fix VibeGuard validation drift (#267)",
          "timestamp": "2026-05-31T16:28:24+08:00",
          "tree_id": "6b7546086cf67ff25a4dde617f3993d26106871b",
          "url": "https://github.com/majiayu000/vibeguard/commit/b3ae510b93fab05e9bb0c0e8ba04c8bf0f1dd8d1"
        },
        "date": 1780216513571,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 108,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 56,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 58,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 58,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 120,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 120,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 125,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 125,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 23,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "6980dbc37235f87733ea46b9a32d23d37f521f71",
          "message": "P1: make setup/check prove repo git hook health (#269)\n\n* Check repo git hook install health\n\n* Use absolute repo hook paths",
          "timestamp": "2026-05-31T17:01:46+08:00",
          "tree_id": "4875cf5f380495863605f3e0140ed21c05596e08",
          "url": "https://github.com/majiayu000/vibeguard/commit/6980dbc37235f87733ea46b9a32d23d37f521f71"
        },
        "date": 1780218582309,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 145,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 167,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 167,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 154,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 154,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 162,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 162,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "b3526569188c8e4780fcb1ce15c48e65cfbf6555",
          "message": "Align L1 enforcement docs with warn default (#271)",
          "timestamp": "2026-05-31T17:13:18+08:00",
          "tree_id": "62fe6ea836cf2cc842475a0bfcd4368659279170",
          "url": "https://github.com/majiayu000/vibeguard/commit/b3526569188c8e4780fcb1ce15c48e65cfbf6555"
        },
        "date": 1780219172429,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 108,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 128,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 128,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 56,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 57,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 57,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 119,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 119,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 124,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 124,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 17,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "58aac2b591d1ccf9ca6238a6fe13f60363bdd8a8",
          "message": "Clarify stop-guard as non-blocking signal\n\nDescribe stop-guard as a non-blocking Stop signal across public docs, setup comments, hook manifest docs, and CI validation.",
          "timestamp": "2026-05-31T17:36:07+08:00",
          "tree_id": "8e2354bd817a9c605bcd47911afc75f6d8c11911",
          "url": "https://github.com/majiayu000/vibeguard/commit/58aac2b591d1ccf9ca6238a6fe13f60363bdd8a8"
        },
        "date": 1780220757740,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 131,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 145,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 145,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "5d1ae0d22f50430a21b9d36a4dbd82752b0fba92",
          "message": "Run cargo fmt check in Rust pre-commit guard\n\nAdd cargo fmt -- --check before cargo check in the Rust pre-commit branch and cover both failing and passing fmt paths.",
          "timestamp": "2026-05-31T17:46:02+08:00",
          "tree_id": "4e4010b0f0749ced4601e2a3791f9eefc070734b",
          "url": "https://github.com/majiayu000/vibeguard/commit/5d1ae0d22f50430a21b9d36a4dbd82752b0fba92"
        },
        "date": 1780221196043,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 108,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 125,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 125,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 55,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 56,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 56,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 15,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 118,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 118,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 123,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 123,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 16,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 17,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "c489d10c6de6245f3e0c68e4e90fb1f7f92deb80",
          "message": "Add safe-bash guard pack receipts\n\nCloses #264.\n\nSummary:\n- add a schema-backed safe-bash guard pack manifest and docs\n- add dry-run/receipt install and uninstall plumbing without changing runtime hooks\n- tighten audit path checks so only canonical VibeGuard hook wrappers qualify\n\nValidation:\n- independent review thread 019e7d6e-c2f3-7db0-bc17-d4a8a8975f22: No findings; safe to merge\n- bash tests/test_guard_packs.sh\n- bash tests/test_manifest_contract.sh\n- bash tests/test_setup.sh\n- bash scripts/ci/validate-doc-paths.sh\n- bash scripts/ci/validate-doc-command-paths.sh\n- cargo check --manifest-path vibeguard-runtime/Cargo.toml\n- cargo test --manifest-path vibeguard-runtime/Cargo.toml\n- GitHub Actions run 26709718134 green",
          "timestamp": "2026-05-31T18:17:52+08:00",
          "tree_id": "5bbaa6cc6c6ba3fd80fc8da038ccf39f34840a81",
          "url": "https://github.com/majiayu000/vibeguard/commit/c489d10c6de6245f3e0c68e4e90fb1f7f92deb80"
        },
        "date": 1780223134280,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 139,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 165,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 165,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 161,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 161,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "01f5e32f510b9194c81acabce2e160f13e8b3099",
          "message": "Fix review follow-ups from issue 262\n\nFixes #262.\n\nSummary:\n- apply the unresolved review-thread fixes collected in issue #262 across hook identity, discard safety, hook performance validation, live truth, skill validation, warn policy, setup/install status, eval, workflow schema/docs, install-state tracking, rule recognition evidence, manifest registration, app-server stdout drain, and skill frontmatter validation\n- keep the branch updated with latest main including guard-pack manifest/setup changes from #265\n- add focused regression coverage for the changed surfaces\n\nValidation:\n- independent review thread 019e7d8c-15c2-71b1-91e1-0d0fcfc1db7b: No findings; safe to merge\n- git diff --check origin/main...HEAD\n- python3 -m py_compile scripts/authorized-discard.py scripts/live_truth.py scripts/skill_validate.py hooks/_lib/policy.py eval/samples.py eval/run_behavior_eval.py scripts/ci/validate-skill-format.py scripts/lib/workflow_contracts.py\n- bash -n changed shell scripts\n- focused shell regression tests for authorized discard, hook perf, live truth, skill validation, setup check, eval, workflow contracts, skill format, manifest, log timer, runtime policy\n- bash scripts/ci/validate-doc-paths.sh\n- bash scripts/ci/validate-doc-command-paths.sh\n- bash scripts/ci/validate-rules.sh\n- bash scripts/ci/validate-canonical-rule-language.sh\n- bash scripts/ci/validate-generated-rule-docs.sh\n- bash tests/test_setup.sh\n- cargo fmt --manifest-path vibeguard-runtime/Cargo.toml --check\n- cargo check --manifest-path vibeguard-runtime/Cargo.toml\n- cargo test --manifest-path vibeguard-runtime/Cargo.toml\n- GitHub Actions run 26709927869 green",
          "timestamp": "2026-05-31T18:27:27+08:00",
          "tree_id": "e55b9d92610275c42fe67e06c51cfab16a803f84",
          "url": "https://github.com/majiayu000/vibeguard/commit/01f5e32f510b9194c81acabce2e160f13e8b3099"
        },
        "date": 1780223692039,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 130,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "9f7019aadfa16e63d6c622e26338e3a7c186a49a",
          "message": "Fix review thread followups\n\nFixes #258.\n\nSummary:\n- reject indented non-YAML frontmatter lines while preserving legal YAML block scalars, including numeric/chomping indicator order variants\n- make the W-15 root-relative doc path regression hermetic\n- make pre-edit fallback report git ls-files lookup failures as normal block JSON\n- replace ineffective warn-mode escalation advice with effective recovery knobs\n\nValidation:\n- independent review thread 019e7d96-4879-72e1-822d-112418ecca97: first found YAML indicator-order edge case; fixed; re-review returned No findings; safe to merge\n- python3 -m py_compile scripts/ci/validate-skill-format.py\n- bash tests/test_skill_format.sh\n- bash scripts/ci/validate-skill-format.sh\n- bash tests/hooks/test_pre_edit_guard.sh\n- bash tests/hooks/test_pre_write_guard.sh\n- bash tests/hooks/test_post_edit_w15.sh\n- bash scripts/ci/validate-doc-paths.sh\n- bash scripts/ci/validate-doc-command-paths.sh\n- cargo fmt --manifest-path vibeguard-runtime/Cargo.toml --check\n- cargo check --manifest-path vibeguard-runtime/Cargo.toml\n- cargo test --manifest-path vibeguard-runtime/Cargo.toml\n- bash tests/test_setup.sh\n- GitHub Actions run 26710299426 green",
          "timestamp": "2026-05-31T18:45:25+08:00",
          "tree_id": "efcb82cbc59a918979731778c0ff40aa9850016e",
          "url": "https://github.com/majiayu000/vibeguard/commit/9f7019aadfa16e63d6c622e26338e3a7c186a49a"
        },
        "date": 1780224812518,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 136,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 162,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 162,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 161,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 161,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "ce31fe816e3264385fe4724bb1f95b12ce558be5",
          "message": "Add Codex hook status diagnostics (#274)\n\n* Add Codex hook status diagnostics\n\nFixes #257\n\n* Add Codex hook status diagnostics\n\nFixes #257\n\n* Fix hook status review findings\n\n* Stabilize hook running status ordering\n\n* Recognize explicit hook status diagnostics",
          "timestamp": "2026-05-31T19:54:54+08:00",
          "tree_id": "38aca07c7121ce61727328451f8832b9d9f09537",
          "url": "https://github.com/majiayu000/vibeguard/commit/ce31fe816e3264385fe4724bb1f95b12ce558be5"
        },
        "date": 1780228964042,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 76,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 77,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 77,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 171,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 171,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "88d843f7bdf816783bbbe03cd91be55443a174c6",
          "message": "Add U-16 typical-size advisories (#275)\n\n* Add U-16 typical-size advisories\n\n* Preserve new-source blocking for U-16 advisories",
          "timestamp": "2026-05-31T20:30:15+08:00",
          "tree_id": "d6607c3244ac15b4994659f5e7e6c4a1e2cbc1ee",
          "url": "https://github.com/majiayu000/vibeguard/commit/88d843f7bdf816783bbbe03cd91be55443a174c6"
        },
        "date": 1780231090018,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 154,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 176,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 176,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 70,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 157,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 157,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "8bac102dcebbc52a06c0dba7206105f73487effd",
          "message": "Point U-17 and U-23 at U-29 guidance (#277)",
          "timestamp": "2026-05-31T20:44:58+08:00",
          "tree_id": "901c2045a29419679c61433d2a056cf12c8507d3",
          "url": "https://github.com/majiayu000/vibeguard/commit/8bac102dcebbc52a06c0dba7206105f73487effd"
        },
        "date": 1780231955099,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 171,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 171,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "39aab192737e61626bcd1bcfae27a1fd88ab2cc9",
          "message": "Point U-08 at verification guidance (#279)",
          "timestamp": "2026-05-31T20:56:38+08:00",
          "tree_id": "71cbc966db31a291d80fa072f04726c1dc86dc2a",
          "url": "https://github.com/majiayu000/vibeguard/commit/39aab192737e61626bcd1bcfae27a1fd88ab2cc9"
        },
        "date": 1780232659151,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 175,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 175,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 69,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "e757be544cf491eb6b0316021a36a5660329562a",
          "message": "Document lint boundary for language rules (#283)",
          "timestamp": "2026-05-31T21:31:45+08:00",
          "tree_id": "69805ab2acbee24761d7b9e14b78e9865441a638",
          "url": "https://github.com/majiayu000/vibeguard/commit/e757be544cf491eb6b0316021a36a5660329562a"
        },
        "date": 1780234793683,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 162,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 186,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 186,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 156,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 156,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 166,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 166,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "0457530ad3276515902cdec34aaf0f9edf494304",
          "message": "Scope narrow common rule loading (#285)\n\n* Scope narrow common rule loading\n\n* Stabilize scoped rule id assertions\n\n* Narrow eval rule path scope",
          "timestamp": "2026-05-31T22:03:38+08:00",
          "tree_id": "05a253bd9f8c62fe167637da3490fad6a8ca7f8b",
          "url": "https://github.com/majiayu000/vibeguard/commit/0457530ad3276515902cdec34aaf0f9edf494304"
        },
        "date": 1780236683038,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 159,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 184,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 184,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "59c8e1c3621d5eb68e3efbf6bd75cc7ae58faea1",
          "message": "Validate preflight routing contract (#287)\n\nValidate preflight routing contract",
          "timestamp": "2026-05-31T22:21:25+08:00",
          "tree_id": "63a9297446f9ad60abcc7c3a769a53626ea27a1d",
          "url": "https://github.com/majiayu000/vibeguard/commit/59c8e1c3621d5eb68e3efbf6bd75cc7ae58faea1"
        },
        "date": 1780237672595,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 57,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 58,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 58,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 122,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 122,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 17,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "742a2faffbcc3a53a71f6ad564931d51e075fa5a",
          "message": "Register optflow routing contract (#289)\n\nRegister optflow routing contract",
          "timestamp": "2026-05-31T22:35:48+08:00",
          "tree_id": "32ae4d41f119903fae47e5fdf59ce86a6afffa11",
          "url": "https://github.com/majiayu000/vibeguard/commit/742a2faffbcc3a53a71f6ad564931d51e075fa5a"
        },
        "date": 1780238610371,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 171,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 171,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 143,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "cffa15ea39a52892219b2cb02a12add4faa45047",
          "message": "Fix auto-optimize compliance check path (#291)\n\nFix auto-optimize compliance check path",
          "timestamp": "2026-05-31T22:54:43+08:00",
          "tree_id": "2f3bf66a0bf6d14706642b35234f4dd850982d40",
          "url": "https://github.com/majiayu000/vibeguard/commit/cffa15ea39a52892219b2cb02a12add4faa45047"
        },
        "date": 1780239743558,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 142,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 142,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "df2c7f00bf6eb030cab26d9f375c18d6b9f9f9be",
          "message": "Merge pull request #293 from majiayu000/codex/validate-skill-template-format\n\nValidate skill template format",
          "timestamp": "2026-05-31T23:13:49+08:00",
          "tree_id": "7f5ac1b6045a6e49fb62edc8130cdbb9efed4056",
          "url": "https://github.com/majiayu000/vibeguard/commit/df2c7f00bf6eb030cab26d9f375c18d6b9f9f9be"
        },
        "date": 1780240904948,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 164,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 187,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 187,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 157,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 157,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 166,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 166,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "926b05bfe89b8bea468316f9de094c41cad5702f",
          "message": "Merge pull request #295 from majiayu000/codex/validate-command-output-schemas\n\nValidate command output schema examples",
          "timestamp": "2026-05-31T23:35:33+08:00",
          "tree_id": "540bfb180c31530d3e26881509afd212df455b92",
          "url": "https://github.com/majiayu000/vibeguard/commit/926b05bfe89b8bea468316f9de094c41cad5702f"
        },
        "date": 1780242220107,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 167,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 192,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 192,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 76,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 77,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 77,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 168,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 168,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "bfa8690af2383133f3ea7ccb1e108793f3f75232",
          "message": "Merge pull request #297 from majiayu000/codex/count-nonnumeric-rule-ids\n\nCount non-numeric rule IDs in rule banners",
          "timestamp": "2026-06-01T00:04:38+08:00",
          "tree_id": "d51800564305e7821abe83afbe8b221a8ebfeb50",
          "url": "https://github.com/majiayu000/vibeguard/commit/bfa8690af2383133f3ea7ccb1e108793f3f75232"
        },
        "date": 1780243945878,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 157,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 157,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "632420f43572ef069aef74baa0511cce60102eec",
          "message": "Merge pull request #299 from majiayu000/codex/scope-agent-health\n\nScope setup agent health to managed agents",
          "timestamp": "2026-06-01T00:24:27+08:00",
          "tree_id": "93440dfaf6758e05808103c9367d3b1393ef7bcd",
          "url": "https://github.com/majiayu000/vibeguard/commit/632420f43572ef069aef74baa0511cce60102eec"
        },
        "date": 1780245136411,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 191,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 191,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 155,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 155,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 161,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 161,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "b3c36a13829a8e928c4528f0cd7bb2017db913c9",
          "message": "Merge pull request #301 from majiayu000/codex/align-hook-semantics-docs\n\nAlign hook docs with current enforcement semantics",
          "timestamp": "2026-06-01T01:02:09+08:00",
          "tree_id": "aae61f13e61f61b56641ae8535f67c77ba23f689",
          "url": "https://github.com/majiayu000/vibeguard/commit/b3c36a13829a8e928c4528f0cd7bb2017db913c9"
        },
        "date": 1780247405294,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 159,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 187,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 187,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 72,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 153,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "59c4143d521975023c8b73ea2e9cf9ce92a3873e",
          "message": "Merge pull request #303 from majiayu000/codex/scope-rule-banner-checks\n\nCheck managed rule banner counts",
          "timestamp": "2026-06-01T01:26:05+08:00",
          "tree_id": "b5fa20a7c9402b0f9a8ffeaee958ce7b9ac1caa3",
          "url": "https://github.com/majiayu000/vibeguard/commit/59c4143d521975023c8b73ea2e9cf9ce92a3873e"
        },
        "date": 1780248832622,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 142,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 142,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "76d3f3b4e781469d20d92c44be6a497d2395e3c1",
          "message": "Merge pull request #305 from majiayu000/codex/worktree-stable-git-hooks\n\nStabilize repo git hook checks across worktrees",
          "timestamp": "2026-06-01T02:00:23+08:00",
          "tree_id": "edf3b55cac5884400c7de6e333464fa4d44135d7",
          "url": "https://github.com/majiayu000/vibeguard/commit/76d3f3b4e781469d20d92c44be6a497d2395e3c1"
        },
        "date": 1780250905092,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 170,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 196,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 196,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 77,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 79,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 79,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 166,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 166,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 23,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "6e321ae9c2de445caa2e1a399b94749f37825467",
          "message": "Merge pull request #307 from majiayu000/codex/install-vg-shortcut-commands\n\nInstall /vg shortcut commands",
          "timestamp": "2026-06-01T02:41:23+08:00",
          "tree_id": "84813ee97ce437b7c649358c8057e78179883556",
          "url": "https://github.com/majiayu000/vibeguard/commit/6e321ae9c2de445caa2e1a399b94749f37825467"
        },
        "date": 1780253376631,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 172,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 144,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "b6e23afda0b1142c9c88c9fbf1bff0623aded177",
          "message": "Merge pull request #309 from majiayu000/codex/align-layer-enforcement-wording\n\nAlign L1-L7 enforcement wording",
          "timestamp": "2026-06-01T03:05:40+08:00",
          "tree_id": "8d5d52055256efa2455460ef4f6a1ab08e13d7fd",
          "url": "https://github.com/majiayu000/vibeguard/commit/b6e23afda0b1142c9c88c9fbf1bff0623aded177"
        },
        "date": 1780254833221,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 173,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 173,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 147,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 147,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 30,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 30,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "fce6908ba598718c54d7fd8cdff449ff7fe7d307",
          "message": "Merge pull request #311 from majiayu000/codex/check-installed-snapshot-drift\n\nReport installed snapshot drift",
          "timestamp": "2026-06-01T03:29:57+08:00",
          "tree_id": "d284a81d57e6aa6fd1e31d5e606cafd6daf2cd79",
          "url": "https://github.com/majiayu000/vibeguard/commit/fce6908ba598718c54d7fd8cdff449ff7fe7d307"
        },
        "date": 1780256364914,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 146,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 168,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 168,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 66,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 66,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 66,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 147,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 147,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "d44b80f76e92604ff6a6962949e0f6af75630471",
          "message": "Merge pull request #313 from majiayu000/codex/check-claude-symlink-drift\n\nDetect stale Claude rule and skill symlink targets",
          "timestamp": "2026-06-01T03:47:45+08:00",
          "tree_id": "d26e7f0ccbad59c004ab9c5fec8270c89489c304",
          "url": "https://github.com/majiayu000/vibeguard/commit/d44b80f76e92604ff6a6962949e0f6af75630471"
        },
        "date": 1780257343329,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 170,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 170,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 67,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 68,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 141,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 151,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 20,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "80c80e58c43d8731843f4a2399ae112e99a407ae",
          "message": "Merge pull request #315 from majiayu000/codex/ci-prompt-contract-validation\n\nRun prompt contract checks in CI",
          "timestamp": "2026-06-01T04:03:31+08:00",
          "tree_id": "2f75046bb3db507f98c8bccf72d399cb55eb943c",
          "url": "https://github.com/majiayu000/vibeguard/commit/80c80e58c43d8731843f4a2399ae112e99a407ae"
        },
        "date": 1780258294578,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 128,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 147,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 147,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 58,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 58,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 58,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 126,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 126,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 17,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "c7ad90d21ebfa2f6c3130a76304b9b9a4bda166b",
          "message": "Merge pull request #317 from majiayu000/codex/track-git-pre-push-manifest\n\nTrack git pre-push hook in manifest",
          "timestamp": "2026-06-01T04:21:42+08:00",
          "tree_id": "a6fbf3e7339f4bd6ac9a232c73389044561aebdf",
          "url": "https://github.com/majiayu000/vibeguard/commit/c7ad90d21ebfa2f6c3130a76304b9b9a4bda166b"
        },
        "date": 1780259408504,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 161,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 181,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 181,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 70,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 70,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 70,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 149,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 160,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "f3ae3fa6dca40e75373ac9c13e0d5c47c978c55a",
          "message": "Align post hook decision types\n\nFixes #318",
          "timestamp": "2026-06-01T04:36:41+08:00",
          "tree_id": "4fdc4e6c6ba024be02c31018b7286c4341fe5086",
          "url": "https://github.com/majiayu000/vibeguard/commit/f3ae3fa6dca40e75373ac9c13e0d5c47c978c55a"
        },
        "date": 1780260287855,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 152,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 176,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 176,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 70,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 71,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 148,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 156,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 156,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 20,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 21,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "143db51814042da4503ed3b5f7db605016e2ac5a",
          "message": "Register entrypoint workflow consumers\n\nFixes #320",
          "timestamp": "2026-06-01T04:50:31+08:00",
          "tree_id": "3d456ed302e39675d57f8c3214480301551ba941",
          "url": "https://github.com/majiayu000/vibeguard/commit/143db51814042da4503ed3b5f7db605016e2ac5a"
        },
        "date": 1780261126310,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 23,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 24,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 162,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 192,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 192,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 73,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 74,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 21,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 154,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 154,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 163,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 163,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 22,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 22,
            "unit": "ms"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "1835304752@qq.com",
            "name": "lif",
            "username": "majiayu000"
          },
          "committer": {
            "email": "noreply@github.com",
            "name": "GitHub",
            "username": "web-flow"
          },
          "distinct": true,
          "id": "915c1864dbba50c95cdd43be2942b26ef8f6a631",
          "message": "Align skill_validate format output with schema\n\nFixes #322",
          "timestamp": "2026-06-01T05:11:42+08:00",
          "tree_id": "140a9ebe1fad3fa0fe8cb4ebc8d241ede151ee8d",
          "url": "https://github.com/majiayu000/vibeguard/commit/915c1864dbba50c95cdd43be2942b26ef8f6a631"
        },
        "date": 1780262338076,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "pre-edit-guard (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P95)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-edit-guard (P99)",
            "value": 19,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P50)",
            "value": 129,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P95)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "pre-write-guard (P99)",
            "value": 150,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P50)",
            "value": 56,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P95)",
            "value": 56,
            "unit": "ms"
          },
          {
            "name": "pre-bash-guard (P99)",
            "value": 56,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P95)",
            "value": 124,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (100) (P99)",
            "value": 124,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (100) (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P50)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P95)",
            "value": 126,
            "unit": "ms"
          },
          {
            "name": "post-edit-guard (5000) (P99)",
            "value": 126,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P95)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "post-write-guard (5000) (P99)",
            "value": 18,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "stop-guard (5000) (P99)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P50)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P95)",
            "value": 17,
            "unit": "ms"
          },
          {
            "name": "learn-evaluator (5000) (P99)",
            "value": 17,
            "unit": "ms"
          }
        ]
      }
    ]
  }
}