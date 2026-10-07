use super::required_string;
use crate::Result;
use serde_json::{Value, json};

pub(super) fn is_event(input: &Value) -> bool {
    input.get("hookEventName").is_some()
        || input.get("toolName").is_some()
        || input.get("tool_name").and_then(Value::as_str) == Some("run_terminal_command")
}

pub(super) fn normalize(input: &mut Value) -> Result<()> {
    let fields = input
        .as_object_mut()
        .ok_or("hook input must be a JSON object")?;
    // Grok's camelCase fields are authoritative; these are its documented aliases.
    for (native, common) in [
        ("toolName", "tool_name"),
        ("toolInput", "tool_input"),
        ("toolResult", "tool_response"),
        ("toolUseId", "tool_use_id"),
        ("isInterrupt", "is_interrupt"),
    ] {
        if let Some(value) = fields.get(native).cloned() {
            fields.insert(common.into(), value);
        }
    }
    let event = if fields.contains_key("hookEventName") {
        required_string(input, "hookEventName")?
    } else {
        required_string(input, "hook_event_name")?
    };
    let event = match event {
        "pre_tool_use" | "PreToolUse" => "PreToolUse",
        "post_tool_use" | "PostToolUse" => "PostToolUse",
        "post_tool_use_failure" | "PostToolUseFailure" => "PostToolUseFailure",
        _ => return Err("unsupported hook event for this host".into()),
    };
    if event == "PreToolUse"
        && input.get("toolInputTruncated").and_then(Value::as_bool) == Some(true)
    {
        return Err("cannot evaluate truncated Grok tool input".into());
    }
    input["hook_event_name"] = json!(event);
    Ok(())
}
