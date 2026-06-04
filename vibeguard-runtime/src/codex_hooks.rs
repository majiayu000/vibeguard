//! Codex hook protocol helpers used by run-hook-codex.sh.

use crate::hook_checks_common::{read_stdin, truncate_chars};
use serde_json::Value;

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

fn ensure_no_args(args: &[String], usage: &str) -> Result {
    if args.is_empty() {
        Ok(())
    } else {
        Err(usage.into())
    }
}

fn read_json_tolerant() -> std::io::Result<Option<Value>> {
    let input = read_stdin()?;
    Ok(serde_json::from_str(&input).ok())
}

fn codex_event_name(data: &Value) -> &str {
    data.get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or("")
}

fn codex_status_matcher(data: &Value) -> &str {
    data.get("tool_name").and_then(Value::as_str).unwrap_or("")
}

fn codex_status_detail(data: &Value) -> String {
    let Some(tool_input) = data.get("tool_input").and_then(Value::as_object) else {
        return String::new();
    };
    for key in ["file_path", "command"] {
        if let Some(value) = tool_input.get(key).and_then(Value::as_str)
            && !value.is_empty()
        {
            return truncate_chars(value, 300);
        }
    }
    String::new()
}

fn codex_status_from_output(data: &Value) -> (String, String) {
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
        .replace('\t', " ")
        .replace('\n', " ");

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

pub fn event_name(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-event-name")?;
    let data = read_json_tolerant()?;
    println!("{}", data.as_ref().map(codex_event_name).unwrap_or(""));
    Ok(())
}

pub fn status_detail(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-status-detail")?;
    let data = read_json_tolerant()?;
    println!(
        "{}",
        data.as_ref()
            .map(codex_status_detail)
            .unwrap_or_else(String::new)
    );
    Ok(())
}

pub fn status_matcher(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-status-matcher")?;
    let data = read_json_tolerant()?;
    println!("{}", data.as_ref().map(codex_status_matcher).unwrap_or(""));
    Ok(())
}

pub fn status_from_output(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-status-from-output")?;
    let input = read_stdin()?;
    let Some(data) = serde_json::from_str::<Value>(&input).ok() else {
        println!("hook_error\tinvalid-json");
        return Ok(());
    };
    let (status, reason) = codex_status_from_output(&data);
    println!("{status}\t{reason}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn event_name_reads_codex_hook_event() {
        assert_eq!(
            codex_event_name(&json!({"hook_event_name": "PreToolUse"})),
            "PreToolUse"
        );
        assert_eq!(codex_event_name(&json!({"hook_event_name": 7})), "");
    }

    #[test]
    fn status_detail_prefers_file_path_then_command_and_truncates() {
        assert_eq!(
            codex_status_detail(&json!({
                "tool_input": {"file_path": "src/main.rs", "command": "cargo test"}
            })),
            "src/main.rs"
        );
        assert_eq!(
            codex_status_detail(&json!({"tool_input": {"command": "cargo test"}})),
            "cargo test"
        );
        let long = "x".repeat(350);
        assert_eq!(
            codex_status_detail(&json!({"tool_input": {"command": long}}))
                .chars()
                .count(),
            300
        );
    }

    #[test]
    fn status_matcher_reads_tool_name() {
        assert_eq!(codex_status_matcher(&json!({"tool_name": "Bash"})), "Bash");
        assert_eq!(codex_status_matcher(&json!({"tool_name": null})), "");
    }

    #[test]
    fn status_from_output_maps_decisions_and_nested_denies() {
        assert_eq!(
            codex_status_from_output(&json!({"decision": "block", "reason": "no\tway\nnow"})),
            ("block".to_string(), "no way now".to_string())
        );
        assert_eq!(
            codex_status_from_output(&json!({"decision": "skip"})),
            ("skipped".to_string(), String::new())
        );
        assert_eq!(
            codex_status_from_output(&json!({
                "hookSpecificOutput": {"permissionDecision": "deny"}
            })),
            ("block".to_string(), String::new())
        );
        assert_eq!(
            codex_status_from_output(&json!({
                "hookSpecificOutput": {"decision": {"behavior": "deny"}}
            })),
            ("block".to_string(), String::new())
        );
    }
}
