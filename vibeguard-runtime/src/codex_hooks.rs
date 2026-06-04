//! Codex hook protocol helpers used by run-hook-codex.sh.

use crate::hook_checks_common::{read_stdin, truncate_chars};
use serde_json::{Map, Value, json};
use std::process;

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

fn print_json(value: &Value) -> Result {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}

fn read_json_object_or_invalid_pretool() -> std::io::Result<Map<String, Value>> {
    let input = read_stdin()?;
    match serde_json::from_str::<Value>(&input) {
        Ok(Value::Object(object)) => Ok(object),
        _ => {
            print_json(&json!({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": "VIBEGUARD hook failed: wrapped hook produced invalid JSON.",
                }
            }))
            .ok();
            process::exit(3);
        }
    }
}

fn read_json_object_or_invalid_permission() -> std::io::Result<Map<String, Value>> {
    let input = read_stdin()?;
    match serde_json::from_str::<Value>(&input) {
        Ok(Value::Object(object)) => Ok(object),
        _ => {
            print_json(&json!({
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {
                        "behavior": "deny",
                        "message": "VIBEGUARD hook failed: wrapped hook produced invalid JSON.",
                    },
                }
            }))
            .ok();
            process::exit(3);
        }
    }
}

fn read_json_object_or_exit_3() -> std::io::Result<Map<String, Value>> {
    let input = read_stdin()?;
    match serde_json::from_str::<Value>(&input) {
        Ok(Value::Object(object)) => Ok(object),
        _ => process::exit(3),
    }
}

fn decision_field(object: &Map<String, Value>) -> &str {
    match object.get("decision") {
        None => "pass",
        Some(Value::String(decision)) => decision,
        Some(_) => "",
    }
}

fn string_field<'a>(object: &'a Map<String, Value>, key: &str) -> &'a str {
    object.get(key).and_then(Value::as_str).unwrap_or("")
}

fn has_native_output(object: &Map<String, Value>) -> bool {
    object
        .get("hookSpecificOutput")
        .is_some_and(Value::is_object)
        || object.contains_key("systemMessage")
}

fn updated_input_is_absent_or_null(object: &Map<String, Value>) -> bool {
    !object.contains_key("updatedInput") || object.get("updatedInput") == Some(&Value::Null)
}

fn native_output(object: &Map<String, Value>) -> Map<String, Value> {
    let mut output = Map::new();
    if let Some(system_message) = object.get("systemMessage") {
        output.insert("systemMessage".to_string(), system_message.clone());
    }
    if let Some(hook_specific) = object.get("hookSpecificOutput").and_then(Value::as_object) {
        output.insert(
            "hookSpecificOutput".to_string(),
            Value::Object(hook_specific.clone()),
        );
    }
    output
}

fn print_object_if_not_empty(object: Map<String, Value>) -> Result {
    if !object.is_empty() {
        print_json(&Value::Object(object))?;
    }
    Ok(())
}

fn deny_pretool_payload(reason: &str) -> Value {
    json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    })
}

fn deny_permission_payload(reason: &str) -> Value {
    json!({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "deny",
                "message": reason,
            },
        }
    })
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

pub fn deny_pretool(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-pretool-deny")?;
    let reason = read_stdin()?;
    print_json(&deny_pretool_payload(&reason))
}

pub fn deny_permission(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-permission-deny")?;
    let reason = read_stdin()?;
    print_json(&deny_permission_payload(&reason))
}

pub fn adapt_pretool(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-adapt-pretool")?;
    let object = read_json_object_or_invalid_pretool()?;
    let decision = decision_field(&object);
    let reason = string_field(&object, "reason");
    let updated = object.get("updatedInput").and_then(Value::as_object);
    let native = has_native_output(&object);

    if native && decision == "pass" && updated_input_is_absent_or_null(&object) {
        return print_object_if_not_empty(native_output(&object));
    }

    if decision == "block" {
        let mut hook_specific = object
            .get("hookSpecificOutput")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        hook_specific.insert("hookEventName".to_string(), json!("PreToolUse"));
        hook_specific.insert("permissionDecision".to_string(), json!("deny"));
        hook_specific.insert("permissionDecisionReason".to_string(), json!(reason));
        return print_json(&json!({ "hookSpecificOutput": hook_specific }));
    }

    if decision == "warn" {
        let mut output = if native {
            native_output(&object)
        } else {
            Map::new()
        };
        if !reason.is_empty() {
            output.insert("systemMessage".to_string(), json!(reason));
        }
        return print_object_if_not_empty(output);
    }

    if decision == "allow"
        && let Some(command) = updated
            .and_then(|updated| updated.get("command"))
            .and_then(Value::as_str)
        && !command.is_empty()
    {
        return print_json(&json!({
            "systemMessage": format!(
                "VIBEGUARD note: Codex CLI hooks cannot auto-apply command rewrites. Suggested command: {command}"
            )
        }));
    }

    Ok(())
}

pub fn adapt_posttool(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-adapt-posttool")?;
    let object = read_json_object_or_exit_3()?;
    let decision = decision_field(&object);
    let reason = string_field(&object, "reason");
    let native = has_native_output(&object);

    if native && decision == "pass" {
        return print_object_if_not_empty(native_output(&object));
    }

    if decision == "block" || decision == "escalate" {
        let mut hook_specific = object
            .get("hookSpecificOutput")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        hook_specific.insert("hookEventName".to_string(), json!("PostToolUse"));
        hook_specific
            .entry("additionalContext".to_string())
            .or_insert_with(|| json!(reason));
        return print_json(&json!({
            "decision": "block",
            "reason": reason,
            "hookSpecificOutput": hook_specific,
        }));
    }

    if decision == "warn" {
        let mut output = if native {
            native_output(&object)
        } else {
            Map::new()
        };
        if !reason.is_empty() {
            output.insert("systemMessage".to_string(), json!(reason));
        }
        return print_object_if_not_empty(output);
    }

    Ok(())
}

pub fn adapt_permission_request(args: &[String]) -> Result {
    ensure_no_args(
        args,
        "Usage: vibeguard-runtime codex-adapt-permission-request",
    )?;
    let object = read_json_object_or_invalid_permission()?;
    let decision = decision_field(&object);
    let reason = string_field(&object, "reason");
    let updated = object.get("updatedInput").and_then(Value::as_object);

    if has_native_output(&object) && decision == "pass" && updated_input_is_absent_or_null(&object)
    {
        return print_object_if_not_empty(native_output(&object));
    }

    if decision == "block" {
        return print_json(&deny_permission_payload(reason));
    }

    if decision == "warn" {
        return print_json(&json!({ "systemMessage": reason }));
    }

    if decision == "allow"
        && let Some(command) = updated
            .and_then(|updated| updated.get("command"))
            .and_then(Value::as_str)
        && !command.is_empty()
    {
        return print_json(&json!({
            "systemMessage": format!(
                "VIBEGUARD note: Codex CLI PermissionRequest hooks cannot auto-apply command rewrites. Suggested command: {command}"
            )
        }));
    }

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

    #[test]
    fn native_output_preserves_system_message_and_hook_specific_output() {
        let object = json!({
            "systemMessage": "note",
            "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "context"},
            "ignored": "field",
        })
        .as_object()
        .unwrap()
        .clone();

        let output = Value::Object(native_output(&object));
        assert_eq!(output["systemMessage"], "note");
        assert_eq!(output["hookSpecificOutput"]["additionalContext"], "context");
        assert!(output.get("ignored").is_none());
    }

    #[test]
    fn decision_field_defaults_only_when_missing() {
        let missing = Map::new();
        let mut null_decision = Map::new();
        null_decision.insert("decision".to_string(), Value::Null);
        let mut string_decision = Map::new();
        string_decision.insert("decision".to_string(), json!("warn"));

        assert_eq!(decision_field(&missing), "pass");
        assert_eq!(decision_field(&null_decision), "");
        assert_eq!(decision_field(&string_decision), "warn");
    }

    #[test]
    fn deny_payloads_match_codex_native_shapes() {
        assert_eq!(
            deny_pretool_payload("blocked")["hookSpecificOutput"]["permissionDecision"],
            "deny"
        );
        assert_eq!(
            deny_permission_payload("blocked")["hookSpecificOutput"]["decision"]["behavior"],
            "deny"
        );
    }
}
