use crate::codex_hooks::ensure_no_args;
use crate::hook_checks::common::read_stdin;
use serde_json::{Value, json};

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

const INVALID_OUTPUT_REASON: &str =
    "VIBEGUARD Gemini adapter failed to parse the guard result; the tool call was denied.";

pub(crate) fn route_before_tool(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime gemini-route-before-tool")?;
    let input = read_stdin()?;
    let payload: Value = serde_json::from_str(&input)?;
    let object = payload
        .as_object()
        .ok_or("Gemini BeforeTool payload must be a JSON object")?;
    if object.get("hook_event_name").and_then(Value::as_str) != Some("BeforeTool") {
        return Err("Gemini adapter only accepts BeforeTool events".into());
    }
    if !object.get("tool_input").is_some_and(Value::is_object) {
        return Err("Gemini BeforeTool payload requires an object tool_input".into());
    }
    let route = match object.get("tool_name").and_then(Value::as_str) {
        Some("run_shell_command") => "pre-bash-guard.sh",
        Some("write_file") => "pre-write-guard.sh",
        Some("replace") => "pre-edit-guard.sh",
        Some(_) => return Err("Gemini BeforeTool tool is not supported by VibeGuard".into()),
        None => return Err("Gemini BeforeTool payload requires a string tool_name".into()),
    };
    println!("{route}");
    Ok(())
}

pub(crate) fn adapt_before_tool(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime gemini-adapt-before-tool")?;
    let input = read_stdin()?;
    let output = adapt_guard_output(&input);
    println!("{}", serde_json::to_string(&output)?);
    Ok(())
}

pub(crate) fn deny(args: &[String]) -> Result {
    ensure_no_args(args, "Usage: vibeguard-runtime gemini-deny")?;
    let reason = read_stdin()?;
    let reason = if reason.trim().is_empty() {
        INVALID_OUTPUT_REASON
    } else {
        reason.trim()
    };
    print_deny(reason)?;
    Ok(())
}

fn adapt_guard_output(input: &str) -> Value {
    if input.trim().is_empty() {
        return json!({});
    }
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(input) else {
        return deny_payload(INVALID_OUTPUT_REASON);
    };
    if let Some(updated_input) = object.get("updatedInput").filter(|value| value.is_object()) {
        return json!({
            "decision": "allow",
            "hookSpecificOutput": { "tool_input": updated_input }
        });
    }
    if let Some(context) = object
        .get("hookSpecificOutput")
        .and_then(|value| value.get("additionalContext"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    {
        return json!({ "systemMessage": context });
    }
    let reason = object
        .get("reason")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(INVALID_OUTPUT_REASON);
    match object.get("decision").and_then(Value::as_str) {
        Some("block" | "deny" | "gate" | "escalate") => deny_payload(reason),
        Some("warn" | "correction") => json!({ "systemMessage": reason }),
        Some("allow" | "pass" | "complete") => json!({}),
        _ => deny_payload(INVALID_OUTPUT_REASON),
    }
}

fn deny_payload(reason: &str) -> Value {
    json!({ "decision": "deny", "reason": reason })
}

fn print_deny(reason: &str) -> Result {
    println!("{}", serde_json::to_string(&deny_payload(reason))?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guard_output_maps_to_gemini_before_tool_contract() {
        assert_eq!(adapt_guard_output(""), json!({}));
        assert_eq!(
            adapt_guard_output(r#"{"decision":"block","reason":"unsafe"}"#),
            json!({"decision":"deny","reason":"unsafe"})
        );
        assert_eq!(
            adapt_guard_output(r#"{"decision":"warn","reason":"review"}"#),
            json!({"systemMessage":"review"})
        );
        assert_eq!(adapt_guard_output(r#"{"decision":"pass"}"#), json!({}));
        assert_eq!(
            adapt_guard_output("not-json"),
            deny_payload(INVALID_OUTPUT_REASON)
        );
        assert_eq!(
            adapt_guard_output(
                r#"{"decision":"allow","updatedInput":{"command":"pnpm add serde"}}"#
            ),
            json!({
                "decision": "allow",
                "hookSpecificOutput": {"tool_input": {"command": "pnpm add serde"}}
            })
        );
        assert_eq!(
            adapt_guard_output(r#"{"hookSpecificOutput":{"additionalContext":"search first"}}"#),
            json!({"systemMessage":"search first"})
        );
    }
}
