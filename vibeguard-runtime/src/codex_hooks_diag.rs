//! Codex wrapper diagnostics and visible-failure payload helpers.

use crate::codex_hooks::status_info_from_raw;
use crate::codex_hooks::{deny_permission_payload, deny_pretool_payload, print_json};
use crate::codex_hooks_adapter::adapt_output_for_event;
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

fn hook_status_entry(
    hook_name: &str,
    event_name: &str,
    matcher: &str,
    status: &str,
    reason: &str,
    detail: &str,
    timeout_ms: &str,
) -> Value {
    let mut entry = json!({
        "ts": codex_ts(),
        "cli": "codex",
        "hook": clean_hook_name(hook_name),
        "event": event_name,
        "matcher": matcher,
        "status": status,
        "reason": reason,
        "detail": truncate_chars(detail, 300),
    });
    if let Ok(timeout_ms) = timeout_ms.parse::<u64>() {
        entry["timeout_ms"] = json!(timeout_ms);
    }
    entry
}

#[expect(
    clippy::too_many_arguments,
    reason = "the diagnostic record intentionally mirrors the hook status schema"
)]
fn append_hook_status(
    diag_file: &str,
    hook_name: &str,
    event_name: &str,
    matcher: &str,
    status: &str,
    reason: &str,
    detail: &str,
    timeout_ms: &str,
) -> Result {
    append_codex_jsonl(
        diag_file,
        hook_status_entry(
            hook_name, event_name, matcher, status, reason, detail, timeout_ms,
        ),
    )
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
    append_hook_status(
        &args[0], &args[1], &args[2], &args[3], &args[4], &args[5], &args[6], &args[7],
    )
}

fn status_from_hook_output(data: &Value) -> (String, String) {
    let Some(object) = data.as_object() else {
        return ("hook_error".to_string(), "invalid-json".to_string());
    };

    let decision = object
        .get("decision")
        .and_then(Value::as_str)
        .unwrap_or("pass");
    let reason = object
        .get("reason")
        .and_then(Value::as_str)
        .unwrap_or("")
        .replace(['\t', '\n'], " ");

    let mut status = "pass";
    if matches!(
        decision,
        "warn" | "block" | "gate" | "escalate" | "correction"
    ) {
        status = decision;
    } else if decision == "skip" {
        status = "skipped";
    } else if let Some(hook_specific) = object.get("hookSpecificOutput").and_then(Value::as_object)
    {
        if hook_specific
            .get("permissionDecision")
            .and_then(Value::as_str)
            == Some("deny")
        {
            status = "block";
        }
        if hook_specific
            .get("decision")
            .and_then(Value::as_object)
            .and_then(|decision| decision.get("behavior"))
            .and_then(Value::as_str)
            == Some("deny")
        {
            status = "block";
        }
    }

    (status.to_string(), truncate_chars(&reason, 300))
}

pub fn hook_status_from_output(args: &[String]) -> Result {
    if args.len() != 6 {
        return Err(
            "Usage: vibeguard-runtime codex-hook-status-from-output <diag-file> <hook-name> <event-name> <matcher> <detail> <timeout-ms>"
                .into(),
        );
    }
    let input = read_stdin()?;
    let (status, reason) = match serde_json::from_str::<Value>(&input) {
        Ok(data) => status_from_hook_output(&data),
        Err(_) => ("hook_error".to_string(), "invalid-json".to_string()),
    };
    append_hook_status(
        &args[0], &args[1], &args[2], &args[3], &status, &reason, &args[4], &args[5],
    )
}

pub fn hook_start(args: &[String]) -> Result {
    if args.len() != 3 {
        return Err(
            "Usage: vibeguard-runtime codex-hook-start <diag-file> <hook-name> <timeout-ms>".into(),
        );
    }
    let input = read_stdin()?;
    let status_info = status_info_from_raw(&input);
    append_hook_status(
        &args[0],
        &args[1],
        &status_info.event_name,
        &status_info.matcher,
        "running",
        "",
        &status_info.detail,
        &args[2],
    )?;
    println!("{}", status_info.shell_line());
    Ok(())
}

pub fn finalize_output(args: &[String]) -> Result {
    if args.len() != 6 {
        return Err(
            "Usage: vibeguard-runtime codex-finalize-output <diag-file> <hook-name> <event-name> <matcher> <detail> <timeout-ms>"
                .into(),
        );
    }
    let input = read_stdin()?;
    let (status, reason) = match serde_json::from_str::<Value>(&input) {
        Ok(data) => status_from_hook_output(&data),
        Err(_) => ("hook_error".to_string(), "invalid-json".to_string()),
    };
    append_hook_status(
        &args[0], &args[1], &args[2], &args[3], &status, &reason, &args[4], &args[5],
    )?;
    let (adapter_status, adapted_output) = adapt_output_for_event(&args[2], &input);
    adapted_output.print()?;
    if adapter_status != 0 {
        std::process::exit(adapter_status);
    }
    Ok(())
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

    #[test]
    fn status_from_hook_output_maps_nested_denies() {
        assert_eq!(
            status_from_hook_output(&json!({"decision": "warn", "reason": "a\tb\nc"})),
            ("warn".to_string(), "a b c".to_string())
        );
        assert_eq!(
            status_from_hook_output(&json!({"decision": "skip"})),
            ("skipped".to_string(), String::new())
        );
        assert_eq!(
            status_from_hook_output(&json!({
                "hookSpecificOutput": {"permissionDecision": "deny"}
            })),
            ("block".to_string(), String::new())
        );
        assert_eq!(
            status_from_hook_output(&json!({
                "hookSpecificOutput": {"decision": {"behavior": "deny"}}
            })),
            ("block".to_string(), String::new())
        );
    }
}
