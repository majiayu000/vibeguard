window.BENCHMARK_DATA = {
  "lastUpdate": 1776530679153,
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
      }
    ]
  }
}