//! Codex hook output adapters used by run-hook-codex.sh.

use crate::codex_hooks::{
    deny_permission_payload, deny_pretool_payload, ensure_no_args, print_json,
};
use crate::hook_checks_common::read_stdin;
use serde_json::{Map, Value, json};
use std::io::Write;
use std::process;

type Result = std::result::Result<(), Box<dyn std::error::Error>>;

const ADAPTER_FAILURE_STATUS: i32 = 3;
const INVALID_JSON_REASON: &str = "VIBEGUARD hook failed: wrapped hook produced invalid JSON.";

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum CodexAdaptedOutput {
    Empty,
    Json(Value),
    Raw(String),
}

impl CodexAdaptedOutput {
    pub(crate) fn print(self) -> Result {
        match self {
            CodexAdaptedOutput::Empty => Ok(()),
            CodexAdaptedOutput::Json(value) => print_json(&value),
            CodexAdaptedOutput::Raw(raw) => {
                let mut stdout = std::io::stdout();
                stdout.write_all(raw.as_bytes())?;
                if !raw.is_empty() && !raw.ends_with('\n') {
                    stdout.write_all(b"\n")?;
                }
                Ok(())
            }
        }
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

fn codex_native_output(object: &Map<String, Value>) -> Map<String, Value> {
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

fn adapted_object_if_not_empty(object: Map<String, Value>) -> CodexAdaptedOutput {
    if object.is_empty() {
        CodexAdaptedOutput::Empty
    } else {
        CodexAdaptedOutput::Json(Value::Object(object))
    }
}

pub(crate) fn adapt_output_for_event(event_name: &str, input: &str) -> (i32, CodexAdaptedOutput) {
    match event_name {
        "PreToolUse" => adapt_pretool_result(input),
        "PostToolUse" => adapt_posttool_result(input),
        "PermissionRequest" => adapt_permission_request_result(input),
        _ => (0, CodexAdaptedOutput::Raw(input.to_string())),
    }
}

pub fn adapt_pretool(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-adapt-pretool")?;
    let input = read_stdin()?;
    let (status, output) = adapt_pretool_result(&input);
    output.print()?;
    if status != 0 {
        process::exit(status);
    }
    Ok(())
}

fn adapt_pretool_result(input: &str) -> (i32, CodexAdaptedOutput) {
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(input) else {
        return (
            ADAPTER_FAILURE_STATUS,
            CodexAdaptedOutput::Json(deny_pretool_payload(INVALID_JSON_REASON)),
        );
    };
    (0, adapt_pretool_object(object))
}

fn adapt_pretool_object(object: Map<String, Value>) -> CodexAdaptedOutput {
    let decision = decision_field(&object);
    let reason = string_field(&object, "reason");
    let updated = object.get("updatedInput").and_then(Value::as_object);
    let native = has_native_output(&object);

    if native && decision == "pass" && updated_input_is_absent_or_null(&object) {
        return adapted_object_if_not_empty(codex_native_output(&object));
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
        return CodexAdaptedOutput::Json(json!({ "hookSpecificOutput": hook_specific }));
    }

    if decision == "warn" {
        let mut output = if native {
            codex_native_output(&object)
        } else {
            Map::new()
        };
        if !reason.is_empty() {
            output.insert("systemMessage".to_string(), json!(reason));
        }
        return adapted_object_if_not_empty(output);
    }

    if decision == "allow"
        && let Some(command) = updated
            .and_then(|updated| updated.get("command"))
            .and_then(Value::as_str)
        && !command.is_empty()
    {
        return CodexAdaptedOutput::Json(json!({
            "systemMessage": format!(
                "VIBEGUARD note: Codex CLI hooks cannot auto-apply command rewrites. Suggested command: {command}"
            )
        }));
    }

    CodexAdaptedOutput::Empty
}

pub fn adapt_posttool(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime codex-adapt-posttool")?;
    let input = read_stdin()?;
    let (status, output) = adapt_posttool_result(&input);
    output.print()?;
    if status != 0 {
        process::exit(status);
    }
    Ok(())
}

fn adapt_posttool_result(input: &str) -> (i32, CodexAdaptedOutput) {
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(input) else {
        return (ADAPTER_FAILURE_STATUS, CodexAdaptedOutput::Empty);
    };
    (0, adapt_posttool_object(object))
}

fn adapt_posttool_object(object: Map<String, Value>) -> CodexAdaptedOutput {
    let decision = decision_field(&object);
    let reason = string_field(&object, "reason");
    let native = has_native_output(&object);

    if native && decision == "pass" {
        return adapted_object_if_not_empty(codex_native_output(&object));
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
        return CodexAdaptedOutput::Json(json!({
            "decision": "block",
            "reason": reason,
            "hookSpecificOutput": hook_specific,
        }));
    }

    if decision == "warn" {
        let mut output = if native {
            codex_native_output(&object)
        } else {
            Map::new()
        };
        if !reason.is_empty() {
            output.insert("systemMessage".to_string(), json!(reason));
        }
        return adapted_object_if_not_empty(output);
    }

    CodexAdaptedOutput::Empty
}

pub fn adapt_permission_request(args: &[String]) -> Result {
    ensure_no_args(
        args,
        "Usage: vibeguard-runtime codex-adapt-permission-request",
    )?;
    let input = read_stdin()?;
    let (status, output) = adapt_permission_request_result(&input);
    output.print()?;
    if status != 0 {
        process::exit(status);
    }
    Ok(())
}

fn adapt_permission_request_result(input: &str) -> (i32, CodexAdaptedOutput) {
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(input) else {
        return (
            ADAPTER_FAILURE_STATUS,
            CodexAdaptedOutput::Json(deny_permission_payload(INVALID_JSON_REASON)),
        );
    };
    (0, adapt_permission_request_object(object))
}

fn adapt_permission_request_object(object: Map<String, Value>) -> CodexAdaptedOutput {
    let decision = decision_field(&object);
    let reason = string_field(&object, "reason");
    let updated = object.get("updatedInput").and_then(Value::as_object);

    if has_native_output(&object) && decision == "pass" && updated_input_is_absent_or_null(&object)
    {
        return adapted_object_if_not_empty(codex_native_output(&object));
    }

    if decision == "block" {
        return CodexAdaptedOutput::Json(deny_permission_payload(reason));
    }

    if decision == "warn" {
        return CodexAdaptedOutput::Json(json!({ "systemMessage": reason }));
    }

    if decision == "allow"
        && let Some(command) = updated
            .and_then(|updated| updated.get("command"))
            .and_then(Value::as_str)
        && !command.is_empty()
    {
        return CodexAdaptedOutput::Json(json!({
            "systemMessage": format!(
                "VIBEGUARD note: Codex CLI PermissionRequest hooks cannot auto-apply command rewrites. Suggested command: {command}"
            )
        }));
    }

    CodexAdaptedOutput::Empty
}

#[cfg(test)]
mod tests {
    use super::*;

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

        let output = Value::Object(codex_native_output(&object));
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
    fn invalid_pretool_json_returns_deny_and_status_3() {
        let (status, output) = adapt_output_for_event("PreToolUse", "{");
        assert_eq!(status, ADAPTER_FAILURE_STATUS);
        assert_eq!(
            output,
            CodexAdaptedOutput::Json(deny_pretool_payload(INVALID_JSON_REASON))
        );
    }

    #[test]
    fn posttool_invalid_json_returns_status_3_without_output() {
        let (status, output) = adapt_output_for_event("PostToolUse", "{");
        assert_eq!(status, ADAPTER_FAILURE_STATUS);
        assert_eq!(output, CodexAdaptedOutput::Empty);
    }
}
