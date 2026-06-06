//! Codex wrapper diagnostics and visible-failure payload helpers.

use crate::codex_hooks::{deny_permission_payload, deny_pretool_payload, print_json};
use crate::hook_checks_common::{append_jsonl, read_stdin, truncate_chars};
use crate::time_utils::{format_unix_secs_utc, now_unix_secs};
use serde_json::{Value, json};
use std::path::Path;

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

fn visible_failure_payload(event_name: &str, reason: &str) -> Value {
    match event_name {
        "PreToolUse" => deny_pretool_payload(reason),
        "PermissionRequest" => deny_permission_payload(reason),
        "PostToolUse" => json!({
            "decision": "block",
            "reason": reason,
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": reason,
            },
        }),
        "Stop" => json!({ "stopReason": reason }),
        _ => json!({ "systemMessage": reason }),
    }
}

fn codex_ts() -> String {
    format_unix_secs_utc(now_unix_secs())
}

fn clean_hook_name(name: &str) -> String {
    let without_prefix = name.strip_prefix("vibeguard-").unwrap_or(name);
    without_prefix
        .strip_suffix(".sh")
        .unwrap_or(without_prefix)
        .to_string()
}

fn append_codex_jsonl(path: &str, value: Value) -> Result {
    append_jsonl(Path::new(path), &serde_json::to_string(&value)?)?;
    Ok(())
}

pub fn visible_failure(args: &[String]) -> Result {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime codex-visible-failure <event-name>".into());
    }
    let reason = read_stdin()?;
    print_json(&visible_failure_payload(&args[0], &reason))
}

pub fn diag(args: &[String]) -> Result {
    if args.len() != 6 {
        return Err(
            "Usage: vibeguard-runtime codex-diag <diag-file> <hook-name> <event-name> <reason> <detail> <cwd>"
                .into(),
        );
    }
    append_codex_jsonl(
        &args[0],
        json!({
            "ts": codex_ts(),
            "cli": "codex",
            "hook": args[1],
            "event": args[2],
            "reason": args[3],
            "detail": truncate_chars(&args[4], 300),
            "cwd": args[5],
        }),
    )
}

pub fn hook_status(args: &[String]) -> Result {
    if args.len() != 8 {
        return Err(
            "Usage: vibeguard-runtime codex-hook-status <diag-file> <hook-name> <event-name> <matcher> <status> <reason> <detail> <timeout-ms>"
                .into(),
        );
    }
    let mut entry = json!({
        "ts": codex_ts(),
        "cli": "codex",
        "hook": clean_hook_name(&args[1]),
        "event": args[2],
        "matcher": args[3],
        "status": args[4],
        "reason": args[5],
        "detail": truncate_chars(&args[6], 300),
    });
    if let Ok(timeout_ms) = args[7].parse::<u64>() {
        entry["timeout_ms"] = json!(timeout_ms);
    }
    append_codex_jsonl(&args[0], entry)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn visible_failure_payloads_match_event_contracts() {
        assert_eq!(
            visible_failure_payload("PreToolUse", "blocked")["hookSpecificOutput"]["permissionDecision"],
            "deny"
        );
        assert_eq!(
            visible_failure_payload("PermissionRequest", "blocked")["hookSpecificOutput"]["decision"]
                ["behavior"],
            "deny"
        );
        assert_eq!(
            visible_failure_payload("PostToolUse", "blocked")["decision"],
            "block"
        );
        assert_eq!(
            visible_failure_payload("Stop", "blocked")["stopReason"],
            "blocked"
        );
        assert_eq!(
            visible_failure_payload("", "blocked")["systemMessage"],
            "blocked"
        );
    }

    #[test]
    fn clean_hook_name_removes_codex_wrapper_affixes() {
        assert_eq!(
            clean_hook_name("vibeguard-pre-bash-guard.sh"),
            "pre-bash-guard"
        );
        assert_eq!(clean_hook_name("custom-hook"), "custom-hook");
    }
}
