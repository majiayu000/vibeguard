//! Canonical field names and common enum values for VibeGuard JSONL events.
//!
//! Shell hooks still write JSON, but Rust readers should import these constants
//! instead of retyping event field strings.

pub const UNKNOWN: &str = "unknown";
pub const SESSION_METRICS_SCHEMA_VERSION: u64 = 1;

pub mod field {
    pub const TS: &str = "ts";
    pub const SESSION: &str = "session";
    pub const HOOK: &str = "hook";
    pub const TOOL: &str = "tool";
    pub const DECISION: &str = "decision";
    pub const REASON: &str = "reason";
    pub const DETAIL: &str = "detail";
    pub const DURATION_MS: &str = "duration_ms";
}

pub mod decision {
    pub const PASS: &str = "pass";
    pub const WARN: &str = "warn";
    pub const BLOCK: &str = "block";
    pub const ESCALATE: &str = "escalate";
    pub const CORRECTION: &str = "correction";

    pub const NEGATIVE: [&str; 4] = [WARN, BLOCK, ESCALATE, CORRECTION];
    pub const RULE_REPEAT: [&str; 3] = [WARN, BLOCK, ESCALATE];
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

    pub const RESEARCH_ONLY: [&str; 3] = [READ, GLOB, GREP];
    pub const MUTATING: [&str; 3] = [WRITE, EDIT, BASH];
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
