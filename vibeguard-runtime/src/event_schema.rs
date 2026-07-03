//! Canonical field names and common enum values for VibeGuard JSONL events.
//!
//! Shell hooks still write JSON, but Rust readers should import these constants
//! instead of retyping event field strings.

pub const UNKNOWN: &str = "unknown";
pub const SESSION_METRICS_SCHEMA_VERSION: u64 = 1;

pub mod field {
    pub const TS: &str = "ts";
    pub const SESSION: &str = "session";
    pub const EVENT: &str = "event";
    #[allow(dead_code)]
    pub const EVENT_ID: &str = "event_id";
    #[allow(dead_code)]
    pub const CODE: &str = "code";
    #[allow(dead_code)]
    pub const RULE_ID: &str = "rule_id";
    pub const HOOK: &str = "hook";
    pub const TOOL: &str = "tool";
    pub const MATCHER: &str = "matcher";
    pub const DECISION: &str = "decision";
    pub const STATUS: &str = "status";
    pub const REASON: &str = "reason";
    pub const DETAIL: &str = "detail";
    #[allow(dead_code)]
    pub const PATH: &str = "path";
    pub const DURATION_MS: &str = "duration_ms";
    pub const ELAPSED_MS: &str = "elapsed_ms";
    pub const TIMEOUT_MS: &str = "timeout_ms";
    pub const LOG_PATH: &str = "log_path";
    pub const MODEL_CONTEXT: &str = "model_context";
    pub const SOURCE: &str = "source";
    pub const CLI: &str = "cli";
    pub const AGENT: &str = "agent";
    pub const CLIENT: &str = "client";
    pub const CLIENT_VARIANT: &str = "client_variant";
    pub const WRAPPER: &str = "wrapper";
    pub const SOURCE_CONFIG: &str = "source_config";
    pub const HOOK_PROTOCOL_VERSION: &str = "hook_protocol_version";
    pub const CALLER_EVIDENCE: &str = "caller_evidence";
}

pub mod decision {
    pub const PASS: &str = "pass";
    pub const WARN: &str = "warn";
    pub const BLOCK: &str = "block";
    pub const GATE: &str = "gate";
    pub const ESCALATE: &str = "escalate";
    pub const CORRECTION: &str = "correction";
    pub const COMPLETE: &str = "complete";

    pub const NEGATIVE: [&str; 4] = [WARN, BLOCK, ESCALATE, CORRECTION];
    pub const RULE_REPEAT: [&str; 3] = [WARN, BLOCK, ESCALATE];
}

pub mod status {
    pub const PASS: &str = super::decision::PASS;
    pub const SKIPPED: &str = "skipped";
    pub const WARN: &str = super::decision::WARN;
    pub const BLOCK: &str = super::decision::BLOCK;
    pub const GATE: &str = super::decision::GATE;
    pub const ESCALATE: &str = super::decision::ESCALATE;
    pub const CORRECTION: &str = super::decision::CORRECTION;
    pub const COMPLETE: &str = super::decision::COMPLETE;
    pub const SLOW: &str = "slow";
    pub const TIMEOUT: &str = "timeout";
    pub const RUNNING: &str = "running";
    pub const ADAPTER_ERROR: &str = "adapter_error";
    pub const HOOK_ERROR: &str = "hook_error";
    pub const UNKNOWN: &str = super::UNKNOWN;
}

pub mod hook {
    pub const POST_EDIT_GUARD: &str = "post-edit-guard";
    pub const POST_BUILD_CHECK: &str = "post-build-check";
    pub const ANALYSIS_PARALYSIS_GUARD: &str = "analysis-paralysis-guard";
    pub const STOP_GUARD: &str = "stop-guard";
    pub const LEARN_EVALUATOR: &str = "learn-evaluator";

    pub const SKIP_SESSION_METRICS: [&str; 2] = [STOP_GUARD, LEARN_EVALUATOR];
}

pub mod tool {
    pub const READ: &str = "Read";
    pub const GLOB: &str = "Glob";
    pub const GREP: &str = "Grep";
    pub const WRITE: &str = "Write";
    pub const EDIT: &str = "Edit";
    pub const BASH: &str = "Bash";
    pub const MULTI_EDIT: &str = "MultiEdit";
    pub const NOTEBOOK_EDIT: &str = "NotebookEdit";
    pub const TASK: &str = "Task";
    pub const AGENT: &str = "Agent";
    pub const POST_TOOL_USE: &str = "PostToolUse";

    pub const RESEARCH_ONLY: [&str; 3] = [READ, GLOB, GREP];
    pub const MUTATING: [&str; 8] = [
        WRITE,
        EDIT,
        BASH,
        MULTI_EDIT,
        NOTEBOOK_EDIT,
        TASK,
        AGENT,
        POST_TOOL_USE,
    ];
}

pub mod metric_field {
    pub const SCHEMA_VERSION: &str = "schema_version";
    pub const TS: &str = super::field::TS;
    pub const SESSION: &str = super::field::SESSION;
    pub const EVENT_COUNT: &str = "event_count";
    pub const DECISIONS: &str = "decisions";
    pub const HOOKS: &str = "hooks";
    pub const TOOLS: &str = "tools";
    pub const TOP_EDITED_FILES: &str = "top_edited_files";
    pub const AVG_DURATION_MS: &str = "avg_duration_ms";
    pub const SLOW_OPS: &str = "slow_ops";
    pub const CORRECTION_SIGNALS: &str = "correction_signals";
    pub const WARN_RATIO: &str = "warn_ratio";
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mutating_tools_cover_write_shell_and_dispatch_events() {
        for expected in [
            tool::WRITE,
            tool::EDIT,
            tool::BASH,
            tool::MULTI_EDIT,
            tool::NOTEBOOK_EDIT,
            tool::TASK,
            tool::AGENT,
            tool::POST_TOOL_USE,
        ] {
            assert!(
                tool::MUTATING.contains(&expected),
                "missing mutating tool {expected}"
            );
        }
    }

    #[test]
    fn research_only_tools_do_not_overlap_mutating_tools() {
        assert_eq!(tool::RESEARCH_ONLY, [tool::READ, tool::GLOB, tool::GREP]);
        for research_tool in tool::RESEARCH_ONLY {
            assert!(
                !tool::MUTATING.contains(&research_tool),
                "research-only tool {research_tool} must not reset as mutating"
            );
        }
    }

    #[test]
    fn negative_decisions_exclude_pass_and_terminal_complete() {
        assert_eq!(
            decision::NEGATIVE,
            [
                decision::WARN,
                decision::BLOCK,
                decision::ESCALATE,
                decision::CORRECTION
            ]
        );
        assert!(!decision::NEGATIVE.contains(&decision::PASS));
        assert!(!decision::NEGATIVE.contains(&decision::COMPLETE));
    }
}
