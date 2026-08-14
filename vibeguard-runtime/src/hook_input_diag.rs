use serde_json::Value;

use crate::hook_checks::common::nested_str;

/// Distinguish the three fail-closed input shapes (empty stdin, invalid JSON,
/// well-formed JSON missing the required field) so block events in
/// events.jsonl are diagnosable without the original payload.
pub(crate) fn malformed_input_diagnostic(input: &str, required_field: &str) -> String {
    let required_field = required_field_class(required_field);
    let (category, tool_name_class, hook_event_name_class) = if input.trim().is_empty() {
        ("empty_stdin", "absent_or_invalid", "absent_or_invalid")
    } else if let Ok(data) = serde_json::from_str::<Value>(input) {
        (
            "missing_required_field",
            tool_name_class(&data),
            hook_event_name_class(&data),
        )
    } else {
        ("invalid_json", "absent_or_invalid", "absent_or_invalid")
    };
    format!(
        "category={category} required_field={required_field} input_size={} tool_name_class={tool_name_class} hook_event_name_class={hook_event_name_class}",
        input.len()
    )
}

fn required_field_class(required_field: &str) -> &'static str {
    match required_field {
        "tool_input.command" => "command",
        "tool_input.file_path" => "file_path",
        _ => "other",
    }
}

fn tool_name_class(data: &Value) -> &'static str {
    match nested_str(data, "tool_name").as_deref() {
        Some("Bash") => "bash",
        Some("Write") => "write",
        Some("Edit") => "edit",
        Some("Read") => "read",
        Some(_) => "other",
        None => "absent_or_invalid",
    }
}

fn hook_event_name_class(data: &Value) -> &'static str {
    match nested_str(data, "hook_event_name").as_deref() {
        Some("PreToolUse") => "pre_tool_use",
        Some("PostToolUse") => "post_tool_use",
        Some("Stop") => "stop",
        Some(_) => "other",
        None => "absent_or_invalid",
    }
}
