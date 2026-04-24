window.BENCHMARK_DATA = {
  "lastUpdate": 1777012520105,
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
      }
    ]
  }
}