//! Hook protocol output helpers shared by shell hooks.

use crate::codex_hooks::print_json;
use crate::hook_checks_common::read_stdin;
use serde_json::json;

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

pub fn context(args: &[String]) -> Result {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime hook-context <event-name>".into());
    }
    let context = read_stdin()?;
    print_json(&json!({
        "hookSpecificOutput": {
            "hookEventName": args[0],
            "additionalContext": context,
        }
    }))
}

pub fn stop_reason(args: &[String]) -> Result {
    if !args.is_empty() {
        return Err("Usage: vibeguard-runtime stop-reason".into());
    }
    let reason = read_stdin()?;
    print_json(&json!({ "stopReason": reason }))
}
