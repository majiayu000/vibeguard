window.BENCHMARK_DATA = {
  "lastUpdate": 1776574631056,
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
      }
    ]
  }
}