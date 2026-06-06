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

pub(crate) fn print_json(value: &Value) -> Result {
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

pub(crate) fn deny_pretool_payload(reason: &str) -> Value {
    json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    })
}

pub(crate) fn deny_permission_payload(reason: &str) -> Value {
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

#[derive(Clone, Debug, Eq, PartialEq)]
struct PatchChange {
    kind: String,
    path: String,
    new_path: Option<String>,
    added_lines: Vec<String>,
    removed_lines: Vec<String>,
}

impl PatchChange {
    fn new(kind: &str, path: &str) -> Self {
        Self {
            kind: kind.to_string(),
            path: path.trim().to_string(),
            new_path: None,
            added_lines: Vec::new(),
            removed_lines: Vec::new(),
        }
    }
}

fn finish_patch_change(changes: &mut Vec<PatchChange>, current: &mut Option<PatchChange>) {
    if let Some(change) = current.take() {
        changes.push(change);
    }
}

fn parse_apply_patch(command: &str) -> Vec<PatchChange> {
    let mut changes = Vec::new();
    let mut current: Option<PatchChange> = None;

    for line in command.lines() {
        if let Some(path) = line.strip_prefix("*** Add File: ") {
            finish_patch_change(&mut changes, &mut current);
            current = Some(PatchChange::new("add", path));
            continue;
        }
        if let Some(path) = line.strip_prefix("*** Update File: ") {
            finish_patch_change(&mut changes, &mut current);
            current = Some(PatchChange::new("update", path));
            continue;
        }
        if let Some(path) = line.strip_prefix("*** Delete File: ") {
            finish_patch_change(&mut changes, &mut current);
            current = Some(PatchChange::new("delete", path));
            continue;
        }

        let Some(change) = current.as_mut() else {
            continue;
        };
        if let Some(path) = line.strip_prefix("*** Move to: ") {
            change.new_path = Some(path.trim().to_string());
        } else if let Some(added) = line.strip_prefix('+') {
            change.added_lines.push(added.to_string());
        } else if let Some(removed) = line.strip_prefix('-') {
            change.removed_lines.push(removed.to_string());
        }
    }

    finish_patch_change(&mut changes, &mut current);
    changes
}

fn apply_patch_command(payload: &Map<String, Value>) -> &str {
    payload
        .get("tool_input")
        .and_then(Value::as_object)
        .and_then(|tool_input| tool_input.get("command"))
        .and_then(Value::as_str)
        .unwrap_or("")
}

fn is_apply_patch_payload(payload: &Map<String, Value>) -> bool {
    if payload.get("tool_name").and_then(Value::as_str) == Some("apply_patch") {
        return true;
    }
    apply_patch_command(payload)
        .trim_start()
        .starts_with("*** Begin Patch")
}

fn normalized_tool_payload(
    payload: &Map<String, Value>,
    tool_name: &str,
    tool_input: Value,
) -> Value {
    let mut normalized = payload.clone();
    normalized.insert("tool_name".to_string(), json!(tool_name));
    normalized.insert("tool_input".to_string(), tool_input);
    Value::Object(normalized)
}

fn normalized_apply_patch_payloads(hook_name: &str, payload: &Map<String, Value>) -> Vec<Value> {
    let event = payload
        .get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or("");
    if !matches!(event, "PreToolUse" | "PermissionRequest" | "PostToolUse")
        || !is_apply_patch_payload(payload)
    {
        return vec![Value::Object(payload.clone())];
    }

    let changes = parse_apply_patch(apply_patch_command(payload));
    if changes.is_empty() {
        return vec![Value::Object(payload.clone())];
    }

    if hook_name.contains("pre-write") || hook_name.contains("post-write") {
        return changes
            .into_iter()
            .filter(|change| change.kind == "add")
            .map(|change| {
                normalized_tool_payload(
                    payload,
                    "Write",
                    json!({
                        "file_path": change.path,
                        "content": change.added_lines.join("\n"),
                    }),
                )
            })
            .collect();
    }

    if hook_name.contains("pre-edit") || hook_name.contains("post-edit") {
        return changes
            .into_iter()
            .filter(|change| change.kind != "add")
            .map(|change| {
                let file_path = if change.kind == "update" {
                    change
                        .new_path
                        .clone()
                        .unwrap_or_else(|| change.path.clone())
                } else {
                    change.path.clone()
                };
                let line_delta =
                    change.added_lines.len() as i64 - change.removed_lines.len() as i64;
                normalized_tool_payload(
                    payload,
                    "Edit",
                    json!({
                        "file_path": file_path,
                        "old_string": "",
                        "new_string": change.added_lines.join("\n"),
                        "vibeguard_line_delta": line_delta,
                    }),
                )
            })
            .collect();
    }

    if hook_name.contains("post-build-check") {
        return changes
            .into_iter()
            .map(|change| {
                let file_path = change.new_path.unwrap_or(change.path);
                let tool_name = if change.kind == "add" {
                    "Write"
                } else {
                    "Edit"
                };
                normalized_tool_payload(payload, tool_name, json!({ "file_path": file_path }))
            })
            .collect();
    }

    vec![Value::Object(payload.clone())]
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

pub fn normalize_apply_patch(args: &[String]) -> Result {
    if args.len() != 1 {
        return Err("Usage: vibeguard-runtime codex-normalize-apply-patch <hook-name>".into());
    }

    let input = read_stdin()?;
    let Ok(Value::Object(payload)) = serde_json::from_str::<Value>(&input) else {
        println!("{input}");
        return Ok(());
    };

    for item in normalized_apply_patch_payloads(&args[0], &payload) {
        println!("{}", serde_json::to_string(&item)?);
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

    #[test]
    fn parse_apply_patch_collects_change_shapes() {
        let changes = parse_apply_patch(
            "*** Begin Patch\n*** Add File: src/new.rs\n+fn main() {}\n*** Update File: src/old.rs\n*** Move to: src/current.rs\n-old\n+new\n*** Delete File: src/dead.rs\n-old\n*** End Patch",
        );
        assert_eq!(changes.len(), 3);
        assert_eq!(changes[0].kind, "add");
        assert_eq!(changes[0].added_lines, vec!["fn main() {}".to_string()]);
        assert_eq!(changes[1].new_path.as_deref(), Some("src/current.rs"));
        assert_eq!(changes[1].removed_lines, vec!["old".to_string()]);
        assert_eq!(changes[2].kind, "delete");
    }

    #[test]
    fn normalize_apply_patch_fans_out_by_hook_kind() {
        let payload = json!({
            "hook_event_name": "PreToolUse",
            "tool_name": "apply_patch",
            "tool_input": {
                "command": "*** Begin Patch\n*** Add File: src/new.rs\n+one\n+two\n*** Update File: src/existing.rs\n-old\n+new\n*** End Patch"
            },
        })
        .as_object()
        .expect("payload object")
        .clone();

        let write_payloads =
            normalized_apply_patch_payloads("vibeguard-pre-write-guard.sh", &payload);
        assert_eq!(write_payloads.len(), 1);
        assert_eq!(write_payloads[0]["tool_name"], "Write");
        assert_eq!(write_payloads[0]["tool_input"]["file_path"], "src/new.rs");
        assert_eq!(write_payloads[0]["tool_input"]["content"], "one\ntwo");

        let edit_payloads =
            normalized_apply_patch_payloads("vibeguard-pre-edit-guard.sh", &payload);
        assert_eq!(edit_payloads.len(), 1);
        assert_eq!(edit_payloads[0]["tool_name"], "Edit");
        assert_eq!(
            edit_payloads[0]["tool_input"]["file_path"],
            "src/existing.rs"
        );
        assert_eq!(edit_payloads[0]["tool_input"]["new_string"], "new");
        assert_eq!(edit_payloads[0]["tool_input"]["vibeguard_line_delta"], 0);
    }
}
