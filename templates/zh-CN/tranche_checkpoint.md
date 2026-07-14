# Tranche Checkpoint

这是长时间 agent run 的可选本地运行时 checkpoint。它不替代 GitHub issue、
pull request、label、review、branch，也不替代 SpecRail spec artifact 作为
durable workflow state。

规范 `spec_status` 取值定义在 `checks/specrail_lib.py` 的 `SPEC_STATUSES`；
本模板只展示示例用法。

runtime item 的 `state` 是由 `checks/specrail_lib.py` 中
`RUNTIME_STATE_MAPPING` 映射的交接状态；它不替代 `states.yaml` 中的规范
工作流状态机。

```json
{
  "checkpoint_version": 2,
  "tranche_id": "YYYY-MM-DD-repo-topic-t01",
  "repo": "owner/repo or local/path",
  "scope": "one bounded tranche; name exclusions and non-goals",
  "status": "planning",
  "overall_objective": "drain_all_actionable_issues_and_prs",
  "queue_mode": "bounded_tranche",
  "budget": {
    "basis": "compaction",
    "compaction_budget": 1,
    "item_cap": null,
    "compaction_count": 0,
    "stop_reason": null,
    "budget_override": null
  },
  "tranche_mix": {
    "spec_pr_count": 0,
    "impl_pr_count": 0,
    "consecutive_spec_only": 0,
    "spec_only_declaration": null
  },
  "spec_coverage": {
    "checked_at": null,
    "complete": [],
    "needs_tasks": [],
    "needs_spec": [],
    "umbrella_covered": [],
    "exception_allowed": []
  },
  "goal": {
    "enabled": false,
    "objective": "",
    "status": "",
    "tokens_used": null,
    "token_budget": null
  },
  "goal_candidate": {
    "objective": "Finish this bounded tranche only",
    "done_when": [
      "runtime checkpoint updated",
      "remote truth refreshed",
      "verification evidence recorded"
    ],
    "constraints": [
      "do not read raw Codex session logs",
      "do not paste raw logs into parent context"
    ],
    "blocked_stop_condition": "record blocker and next_action when CI, reviewer, or remote truth is pending"
  },
  "context_budget": {
    "window_tokens": 258400,
    "soft_stop_ratio": 0.5,
    "hard_stop_ratio": 0.65,
    "critical_stop_ratio": 0.75,
    "override_allowed": true
  },
  "output_firewall": {
    "raw_log_policy": "file_only",
    "max_parent_stdout_lines": 150,
    "max_subagent_final_lines": 150,
    "artifact_root": "artifacts/logs/YYYY-MM-DD-repo-topic-t01"
  },
  "thread_dispatch_gate": {
    "explicit_thread_request": "yes",
    "native_subagents": "available",
    "spawn_requirement": "required",
    "fallback_mode": "none",
    "planned_native_threads": [
      {
        "id": "merge-reviewer-1",
        "role": "merge_reviewer",
        "target": "PR #0",
        "write_scope": "read_only",
        "spawn_status": "spawned",
        "no_spawn_reason": null
      }
    ],
    "native_thread_evidence": {
      "spawned_agents": [
        {
          "lane_id": "merge-reviewer-1",
          "spawn_tool": "multi_agent_v1.spawn_agent",
          "agent_id_or_thread_id": "agent-or-thread-id",
          "wait_evidence": "wait_agent completed",
          "close_evidence": "close_agent completed",
          "result_collected": "yes"
        }
      ],
      "fallback_reason": null
    },
    "no_spawn_reason": null
  },
  "items": [
    {
      "issue": null,
      "pr": null,
      "state": "planning",
      "spec_status": null,
      "spec_status_reason": null,
      "branch": null,
      "worktree": null,
      "head_sha": null,
      "truth_level": null,
      "ci": {
        "status": "unknown",
        "run_id": null,
        "evidence": null
      },
      "local_verification": [],
      "review": {
        "reviewer_lane": "merge-reviewer-1",
        "native_thread_id": "agent-or-thread-id",
        "status": "pending",
        "evidence": "artifacts/reviews/YYYY-MM-DD-repo-topic-t01/merge-reviewer-1.json",
        "blocking_findings": []
      },
      "review_threads": {
        "status": "unknown",
        "unresolved_count": null,
        "evidence": null,
        "checked_at": null
      },
      "pr_gate": {
        "status": "unknown",
        "head_sha": null,
        "evidence": null,
        "checked_at": null
      },
      "blocker": null,
      "next_action": "refresh remote truth and write queue gate",
      "merge_state": "not_merge_ready"
    }
  ],
  "remaining_queue": [
    {
      "issue": null,
      "pr": null,
      "spec_status": "needs_spec",
      "spec_status_reason": "missing product.md or tech.md for the issue",
      "state": "needs_spec",
      "blocker": null,
      "next_action": "write or update the SpecRail spec packet before implementation"
    }
  ],
  "worktree_cleanup": {
    "pruned_checkouts": [],
    "stale_or_removed_worktrees": []
  },
  "resume_prompt": "Read this checkpoint, refresh remote truth, and continue only the named tranche. Do not read raw Codex session logs."
}
```
